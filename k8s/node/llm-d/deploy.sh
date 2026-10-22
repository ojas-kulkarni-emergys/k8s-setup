#!/usr/bin/env bash
# Sourced by ../llm-d.setup.sh; service operations remain Bash commands.
select_custom_manifest() {
  local selection i
  local -a manifests=()
  [[ -d "$MANIFESTS_DIR" ]] || { echo "Manifest directory missing: $MANIFESTS_DIR" >&2; return 2; }
  mapfile -t manifests < <(find "$MANIFESTS_DIR" -type f \( -name '*.yaml' -o -name '*.yml' \) ! -path '*/templates/*' ! -path '*/deployments/*' | sort)
  ((${#manifests[@]})) || { echo 'No custom manifests found.' >&2; return 2; }
  echo 'Custom manifests (router / monitoring):'
  for i in "${!manifests[@]}"; do printf '  %d) %s\n' "$((i+1))" "${manifests[$i]#"$MANIFESTS_DIR/"}"; done
  read -r -p 'Choose manifest number (Enter uses configured manifest_path): ' selection || return 1
  if [[ -z "$selection" ]]; then
    DEPLOY_FILE="$EXISTING_MANIFEST"
  else
    [[ "$selection" =~ ^[1-9][0-9]*$ ]] && ((selection<=${#manifests[@]})) || { echo 'Invalid manifest number.' >&2; return 2; }
    DEPLOY_FILE="${manifests[$((selection-1))]}"
  fi
  need_file "$DEPLOY_FILE"
}

show_menu() {
  echo; echo '================================================'; echo '          llm-d Deployment Wizard'; echo '================================================'
  echo "Namespace : $NAMESPACE"; echo "Kubeconfig: $KUBECONFIG"; echo "Model cache: $HF_CACHE"; echo "Background forwarding: systemd / journalctl"; echo
  echo '  1) Apply custom router / monitoring manifest'
  echo '  2) Deploy llm-d router (Helm)'
  echo '  3) Generate/reuse a model manifest and deploy it'
  echo '  4) Deploy a previously generated model manifest'
  echo '  5) Back'
  read -r -p 'Select [1-5]: ' choice
}
deploy_wizard() {
show_menu
case "${choice:-}" in
  1) select_custom_manifest; MODE='custom manifest (namespaces from manifest)' ;;
  2)
    need_file "$BASE_VALUES"; need_file "$OPT_VALUES"; command -v helm >/dev/null || { echo 'ERROR: helm is required for router deployment.' >&2; exit 2; }
    mkdir -p "$(dirname -- "$ROUTER_OUTPUT")"
    echo '==> Rendering router chart (commands are intentionally visible here and documented below)...'
    [[ "$ROUTER_OUTPUT" != "$EXISTING_MANIFEST" ]] || { echo "Use a separate generated_manifest_path for Helm output." >&2; exit 2; }
    render_temp="$(mktemp "${ROUTER_OUTPUT}.XXXXXX")"
    trap 'rm -f "$render_temp"' EXIT
    (cd "$REPO_ROOT" && helm template "$RELEASE_NAME" "$CHART" --namespace "$NAMESPACE" -f "$BASE_VALUES" -f "$OPT_VALUES" --version "$CHART_VERSION") > "$render_temp"
    mv -- "$render_temp" "$ROUTER_OUTPUT"
    trap - EXIT
    DEPLOY_FILE="$ROUTER_OUTPUT"; MODE='llm-d router';;
  3)
    echo; echo 'Available model deployments:'
    for i in "${!MODEL_IDS[@]}"; do printf '  %2d) %-53s [%s]  CPU %s/%s, RAM %s/%s\n' "$((i+1))" "${MODEL_IDS[$i]}" "${MODEL_TYPES[$i]}" "${MODEL_CPU_REQ[$i]}" "${MODEL_CPU_LIM[$i]}" "${MODEL_MEM_REQ[$i]}" "${MODEL_MEM_LIM[$i]}"; done
    read -r -p 'Choose model number: ' model_choice
    [[ "$model_choice" =~ ^[0-9]+$ ]] && (( model_choice >= 1 && model_choice <= ${#MODEL_IDS[@]} )) || { echo 'Invalid model choice.' >&2; exit 2; }
    idx=$((model_choice-1)); MODEL_ID="${MODEL_IDS[$idx]}"; MODEL_TYPE="${MODEL_TYPES[$idx]}"
    DETECTED_ACCELERATOR="$(detect_cluster_gpu)"
    select_accelerator "$DETECTED_ACCELERATOR"
    read -r -p 'Number of replicas [1]: ' REPLICAS; REPLICAS="${REPLICAS:-1}"
    [[ "$REPLICAS" =~ ^[1-9][0-9]*$ ]] || { echo 'Replicas must be a positive integer.' >&2; exit 2; }
    CPU_REQ="${MODEL_CPU_REQ[$idx]}"; CPU_LIM="${MODEL_CPU_LIM[$idx]}"; MEM_REQ="${MODEL_MEM_REQ[$idx]}"; MEM_LIM="${MODEL_MEM_LIM[$idx]}"
    echo; echo 'Resource allocation (defaults are model-specific; press Enter to keep each default).'
    read -r -p "CPU request [$CPU_REQ]: " v; CPU_REQ="${v:-$CPU_REQ}"
    read -r -p "CPU limit [$CPU_LIM]: " v; CPU_LIM="${v:-$CPU_LIM}"
    read -r -p "Memory request [$MEM_REQ]: " v; MEM_REQ="${v:-$MEM_REQ}"
    read -r -p "Memory limit [$MEM_LIM]: " v; MEM_LIM="${v:-$MEM_LIM}"
    read -r -p "Hugging Face cache path [$HF_CACHE]: " v; HF_CACHE="$(resolve_path "${v:-$HF_CACHE}" "$CONFIG_DIR")"
    echo; echo "==> Checking/download model into cache: $MODEL_ID"
    mkdir -p "$HF_CACHE" "$HF_DOWNLOAD_CACHE"
    # The cache check and download happen on the host before creating the workload.
    HF_TOKEN="${HF_TOKEN:-}"
    export HF_HOME="$HF_CACHE" HF_HUB_CACHE="$HF_DOWNLOAD_CACHE"
    python3 - "$MODEL_ID" "$HF_DOWNLOAD_CACHE" "$HF_TOKEN" <<'PYDL'
import os,sys
repo,cache,token=sys.argv[1:]
try:
    from huggingface_hub import snapshot_download
except ImportError:
    raise SystemExit('ERROR: huggingface_hub is required. Install with: python3 -m pip install --user huggingface_hub')
# The standard hub cache uses models--org--repo folder names and refs/snapshots.
slug='models--'+repo.replace('/','--')
repo_dir=os.path.join(cache,slug)
complete=False
if os.path.isdir(os.path.join(repo_dir,'snapshots')):
    complete=False  # Let the hub validate cached files and fetch missing weights.
if complete:
    print(f'Model cache entry exists: {repo_dir}')
else:
    print(f'Model not found in cache; downloading {repo}...')
    snapshot_download(repo_id=repo, cache_dir=cache, token=token or None)
    print('Download completed and stored in Hugging Face cache.')
PYDL
    need_file "$MODEL_TEMPLATE_PATH"
    mkdir -p "$DEPLOYMENTS_DIR"
    slug="$(model_slug "$MODEL_ID")"
    export MODEL_ID MODEL_TYPE REPLICAS CPU_REQ CPU_LIM MEM_REQ MEM_LIM NAMESPACE HF_CACHE HF_DOWNLOAD_CACHE MODEL_TEMPLATE_PATH ACCELERATOR VLLM_IMAGE
    DEPLOY_FILE="$(python3 - "$DEPLOYMENTS_DIR" <<'PYFIND'
import os,sys,glob,yaml
root=sys.argv[1]; model=os.environ['MODEL_ID']; replicas=int(os.environ['REPLICAS']); image=os.environ['VLLM_IMAGE']; cache=os.environ['HF_CACHE']
want={'cpu_req':os.environ['CPU_REQ'],'cpu_lim':os.environ['CPU_LIM'],'mem_req':os.environ['MEM_REQ'],'mem_lim':os.environ['MEM_LIM']}
for path in sorted(glob.glob(os.path.join(root,'*.yaml'))+glob.glob(os.path.join(root,'*.yml'))):
    try:
        with open(path,encoding='utf-8') as f: docs=[d for d in yaml.safe_load_all(f) if isinstance(d,dict)]
    except Exception: continue
    dep=next((d for d in docs if d.get('kind')=='Deployment'),None)
    if not dep: continue
    spec=dep.get('spec',{}); pod=spec.get('template',{}).get('spec',{}); cs=pod.get('containers',[])
    c=next((x for x in cs if x.get('name') in ('vllm','inference')),cs[0] if cs else {})
    args=list(c.get('args') or [])
    try: mi=args.index('--model'); model_now=args[mi+1]
    except (ValueError,IndexError): model_now=''
    res=c.get('resources',{}); req=res.get('requests',{}); lim=res.get('limits',{})
    if model_now==model and int(spec.get('replicas',1))==replicas and c.get('image')==image and req.get('cpu')==want['cpu_req'] and lim.get('cpu')==want['cpu_lim'] and req.get('memory')==want['mem_req'] and lim.get('memory')==want['mem_lim'] and any((v.get('hostPath') or {}).get('path')==cache for v in pod.get('volumes',[])):
        print(path); break
PYFIND
)"
    if [[ -n "$DEPLOY_FILE" ]]; then
      echo "==> Matching manifest already exists; reusing: $DEPLOY_FILE"
    else
      stamp="$(date +%Y%m%d-%H%M%S)"
      OUT_NAME="${slug}.${REPLICAS}replicas.${CPU_REQ//\//-}cpu-${MEM_REQ//\//-}mem.${stamp}.yaml"
      DEPLOY_FILE="$DEPLOYMENTS_DIR/$OUT_NAME"
    fi
    if [[ ! -f "$DEPLOY_FILE" ]]; then
    python3 - "$DEPLOY_FILE" <<'PYGEN'
import os,sys,yaml
out=sys.argv[1]
model=os.environ['MODEL_ID']; typ=os.environ['MODEL_TYPE']; replicas=int(os.environ['REPLICAS'])
slug=''.join(c.lower() if c.isalnum() else '-' for c in model).strip('-').replace('--','-')[:50]
name=slug.strip('-').replace('.','-')[:63].rstrip('-')
namespace=os.environ['NAMESPACE']; cache=os.environ['HF_CACHE']; cpu_req=os.environ['CPU_REQ']; cpu_lim=os.environ['CPU_LIM']; mem_req=os.environ['MEM_REQ']; mem_lim=os.environ['MEM_LIM']
args=['--model',model,'--host','0.0.0.0','--port','8000', '--gpu-memory-utilization', '0.9']
if typ=='embedding': args += ['--task','embed']
with open(os.environ['MODEL_TEMPLATE_PATH'],encoding='utf-8') as f: template=f.read()
scalar=lambda value: yaml.safe_dump(value,default_flow_style=True).splitlines()[0]
replacements={
 '__RELEASE_NAME__': scalar(os.environ['RELEASE_NAME']),
 '__DEPLOYMENT_NAME__': scalar(name),
 '__SERVICE_NAME__': scalar(name+'-service'),
 '__NAMESPACE__': scalar(namespace),
 '__REPLICAS__': str(replicas),
 '__MODEL_ID__': scalar(model),
 '__VLLM_ARGS__': scalar(args),
 '__CACHE_PATH__': scalar(cache),
 '__CPU_REQUEST__': scalar(cpu_req),
 '__CPU_LIMIT__': scalar(cpu_lim),
 '__MEMORY_REQUEST__': scalar(mem_req),
 '__MEMORY_LIMIT__': scalar(mem_lim),
}
for key,value in replacements.items(): template=template.replace(key,value)
docs=[d for d in yaml.safe_load_all(template) if isinstance(d,dict)]
if len(docs)<2: raise SystemExit('Template must contain a Deployment and Service document.')
accelerator=os.environ.get('ACCELERATOR','cpu')
image=os.environ.get('VLLM_IMAGE','vllm/vllm-openai-cpu:latest-x86_64')
deployment=next((d for d in docs if d.get('kind')=='Deployment'),None)
if deployment is None: raise SystemExit('Template must contain a Deployment document.')
pod_spec=deployment.setdefault('spec',{}).setdefault('template',{}).setdefault('spec',{})
containers=pod_spec.get('containers') or []
if not containers: raise SystemExit('Deployment template has no containers.')
# The model-serving container uses the selected runtime image.
container=next((c for c in containers if c.get('name') in ('vllm','inference')),containers[0])
container['image']=image
resources=container.setdefault('resources',{})
limits=resources.setdefault('limits',{})
requests=resources.setdefault('requests',{})
if accelerator=='gpu':
    limits['nvidia.com/gpu']=1
    # Kubernetes uses the GPU limit as the request if no explicit request is set.
    requests.pop('nvidia.com/gpu',None)
else:
    limits.pop('nvidia.com/gpu',None)
    requests.pop('nvidia.com/gpu',None)
if not limits: resources.pop('limits',None)
if not requests: resources.pop('requests',None)
if not resources: container.pop('resources',None)
with open(out,'w',encoding='utf-8') as f: yaml.safe_dump_all(docs,f,sort_keys=False)
print(f'Accelerator: {accelerator.upper()}')
print(f'Inference image: {image}')
print(f'Generated deployment: {out}')
PYGEN
    fi
    MODE="model $MODEL_ID ($REPLICAS replicas)"
    ;;
  4)
    mkdir -p "$DEPLOYMENTS_DIR"
    mapfile -t GENERATED_MANIFESTS < <(find "$DEPLOYMENTS_DIR" -maxdepth 1 -type f \( -iname '*.yaml' -o -iname '*.yml' \) -print | sort)
    if ((${#GENERATED_MANIFESTS[@]} == 0)); then echo "No generated manifests found in $DEPLOYMENTS_DIR"; exit 0; fi
    echo "Generated manifests in $DEPLOYMENTS_DIR:"
    for i in "${!GENERATED_MANIFESTS[@]}"; do printf '  %2d) %s\n' "$((i+1))" "$(basename -- "${GENERATED_MANIFESTS[$i]}")"; done
    read -r -p 'Choose manifest number to deploy: ' manifest_choice
    [[ "$manifest_choice" =~ ^[0-9]+$ ]] && (( manifest_choice >= 1 && manifest_choice <= ${#GENERATED_MANIFESTS[@]} )) || { echo 'Invalid manifest choice.' >&2; exit 2; }
    DEPLOY_FILE="${GENERATED_MANIFESTS[$((manifest_choice-1))]}"
    MODE="previously generated manifest: $(basename -- "$DEPLOY_FILE")"
    ;;
  5) return 0;;
  *) echo 'Invalid selection.' >&2; exit 2;;
esac

export KUBECONFIG="$KUBECONFIG_PATH"
if [[ ! -f "$KUBECONFIG" ]]; then echo "WARNING: kubeconfig not found: $KUBECONFIG" >&2; read -r -p 'Continue anyway? [y/N]: ' ans; [[ "$ans" =~ ^[Yy]$ ]] || exit 1; fi

echo; echo 'Deployment summary'; echo "  Mode: $MODE"; echo "  Namespace: $NAMESPACE"; echo "  Manifest: $DEPLOY_FILE"
if [[ "$choice" == 3 ]]; then
  echo "  Accelerator: ${ACCELERATOR^^}"
  echo "  Inference image: $VLLM_IMAGE"
  echo "  Model cache on host: $HF_CACHE"
  echo '  NOTE: hostPath is node-local; every node that may run replicas must have this same cache path and content.'
fi
read -r -p 'Apply this manifest? [y/N]: ' confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo 'Cancelled; no Kubernetes resources changed (a model may already have been cached locally).'; exit 0; }

KUBECTL=(sudo k8s kubectl)

echo '==> Ensuring namespace exists...'
"${KUBECTL[@]}" create namespace "$NAMESPACE" --dry-run=client -o yaml | "${KUBECTL[@]}" apply -f -
echo '==> Applying manifest...'
if [[ "$choice" == 1 ]]; then
  # Custom documents own their namespace. Namespace documents are applied too.
  "${KUBECTL[@]}" apply -f "$DEPLOY_FILE"
else
  "${KUBECTL[@]}" apply -f "$DEPLOY_FILE" -n "$NAMESPACE"
fi
echo '==> Pods:'
"${KUBECTL[@]}" get pods -n "$NAMESPACE" -o wide
cat <<'CMDS'

Useful commands (kept here for reference; run manually when needed):
  sudo k8s kubectl get pods -n llm-d-deployments -o wide
  sudo k8s kubectl get deployments,services -n llm-d-deployments
  # List likely model-serving deployments:
  # sudo k8s kubectl get deployments -n llm-d-deployments -o wide
  # Remove one manually if required:
  # sudo k8s kubectl delete deployment <deployment-name> -n llm-d-deployments
  sudo k8s kubectl describe deployment <deployment-name> -n llm-d-deployments
  sudo k8s kubectl logs -f deployment/<deployment-name> -n llm-d-deployments
  sudo k8s kubectl rollout status deployment/<deployment-name> -n llm-d-deployments
  sudo k8s kubectl delete -f <generated-manifest.yaml> -n llm-d-deployments
  # Router template command:
  # helm template llm-router ghcr.io/llm-d/charts/llm-d-router-standalone:v0 \
  #   -f guides/recipes/router/base.values.yaml \
  #   -f guides/optimized-baseline/router/optimized-baseline.values.yaml --version v0
  # GPU detection check:
  #   sudo k8s kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.status.allocatable.nvidia\.com/gpu}{"\\n"}{end}'
  # GPU pods require NVIDIA driver/container support and a Kubernetes NVIDIA device plugin.
CMDS

}

