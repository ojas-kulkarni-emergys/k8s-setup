#!/usr/bin/env bash
# Sourced by ../llm-d.setup.sh; service operations remain Bash commands.
CONFIG_INPUT="${1:-$SCRIPT_DIR/../../config.yaml}"
[[ -f "$CONFIG_INPUT" ]] || { echo "ERROR: config file not found: $CONFIG_INPUT" >&2; exit 2; }
CONFIG="$(cd -- "$(dirname -- "$CONFIG_INPUT")" && pwd)/$(basename -- "$CONFIG_INPUT")"
CONFIG_DIR="$(dirname -- "$CONFIG")"

echo "Using config file: $CONFIG (from $CONFIG_DIR)"

command -v python3 >/dev/null || { echo 'ERROR: python3 is required.' >&2; exit 2; }
python3 -c 'import yaml' >/dev/null 2>&1 || { echo 'ERROR: PyYAML missing. Install: sudo apt-get install -y python3-yaml' >&2; exit 2; }

cfg() {
  python3 - "$CONFIG" "$1" <<'PYCFG'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f: data=yaml.safe_load(f) or {}
v=data
for p in sys.argv[2].split('.'):
    v=v.get(p) if isinstance(v,dict) else None
if v is None: print('')
elif isinstance(v,(dict,list)): print(yaml.safe_dump(v, default_flow_style=True).strip())
else: print(str(v))
PYCFG
}
resolve_path() { local p="$1" base="$2"; [[ -n "$p" ]] || { printf ''; return; }; [[ "$p" = /* ]] && printf '%s' "$p" || printf '%s/%s' "$base" "$p"; }

NAMESPACE="$(cfg llm_d.namespace)"; NAMESPACE="${NAMESPACE:-llm-d-deployments}"
RELEASE_NAME="$(cfg llm_d.release_name)"; RELEASE_NAME="${RELEASE_NAME:-llm-router}"
KUBECONFIG_PATH="$(cfg llm_d.kubeconfig)"; KUBECONFIG_PATH="${KUBECONFIG_PATH:-$HOME/.kube/config}"
KUBECONFIG_PATH="$(resolve_path "$KUBECONFIG_PATH" "$CONFIG_DIR")"
REPO_ROOT="$(resolve_path "$(cfg llm_d.repo_root)" "$CONFIG_DIR")"
[[ -n "$REPO_ROOT" ]] || REPO_ROOT="$CONFIG_DIR"
CHART="$(cfg llm_d.chart)"; CHART="${CHART:-ghcr.io/llm-d/charts/llm-d-router-standalone:v0}"
CHART_VERSION="$(cfg llm_d.chart_version)"; CHART_VERSION="${CHART_VERSION:-v0}"
BASE_VALUES="$(cfg llm_d.base_values)"; BASE_VALUES="$(resolve_path "${BASE_VALUES:-guides/recipes/router/base.values.yaml}" "$REPO_ROOT")"
OPT_VALUES="$(cfg llm_d.optimized_values)"; OPT_VALUES="$(resolve_path "${OPT_VALUES:-guides/optimized-baseline/router/optimized-baseline.values.yaml}" "$REPO_ROOT")"
MANIFESTS_DIR="$(resolve_path "$(cfg llm_d.manifests_dir)" "$CONFIG_DIR")"
[[ -n "$MANIFESTS_DIR" ]] || MANIFESTS_DIR="$SCRIPT_DIR/manifests"
EXISTING_MANIFEST="$(cfg llm_d.manifest_path)"; EXISTING_MANIFEST="$(resolve_path "$EXISTING_MANIFEST" "$CONFIG_DIR")"
ROUTER_OUTPUT="$(cfg llm_d.generated_manifest_path)"; ROUTER_OUTPUT="$(resolve_path "${ROUTER_OUTPUT:-k8s/node/manifests/router/llm-d-router.rendered.yaml}" "$CONFIG_DIR")"
HF_CACHE="$(cfg llm_d.hf_cache_path)"; HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
HF_CACHE="$(resolve_path "$HF_CACHE" "$CONFIG_DIR")"
DEPLOYMENTS_DIR="$(cfg llm_d.generated_deployments_dir)"; DEPLOYMENTS_DIR="$(resolve_path "${DEPLOYMENTS_DIR:-k8s/node/manifests/deployments}" "$CONFIG_DIR")"
HF_DOWNLOAD_CACHE="$(cfg llm_d.hf_download_cache_dir)"; HF_DOWNLOAD_CACHE="${HF_DOWNLOAD_CACHE:-$HF_CACHE/hub}"
HF_DOWNLOAD_CACHE="$(resolve_path "$HF_DOWNLOAD_CACHE" "$CONFIG_DIR")"
MODEL_TEMPLATE_PATH="$(cfg llm_d.model_template_path)"; MODEL_TEMPLATE_PATH="$(resolve_path "${MODEL_TEMPLATE_PATH:-k8s/node/manifests/templates/model-deployment.template.yaml}" "$CONFIG_DIR")"
PORT_FORWARD_DIR="$(cfg llm_d.port_forward_dir)"; PORT_FORWARD_DIR="$(resolve_path "${PORT_FORWARD_DIR:-.llm-d-port-forwards}" "$CONFIG_DIR")"
CPU_IMAGE="$(cfg llm_d.cpu_image)"; CPU_IMAGE="${CPU_IMAGE:-vllm/vllm-openai-cpu:latest-x86_64}"
GPU_IMAGE="$(cfg llm_d.gpu_image)"; GPU_IMAGE="${GPU_IMAGE:-vllm/vllm-openai:latest}"

# Kubernetes is the source of truth for GPU scheduling: the node must advertise
# an allocatable nvidia.com/gpu resource (normally via the NVIDIA device plugin).
KUBECTL=(sudo k8s kubectl)
detect_cluster_gpu() {
  "${KUBECTL[@]}" get nodes -o json 2>/dev/null | python3 -c '
import json,sys
try:
    nodes=json.load(sys.stdin).get("items", [])
    print("gpu" if any(int((n.get("status",{}).get("allocatable",{}).get("nvidia.com/gpu","0")) or 0)>0 for n in nodes) else "cpu")
except Exception:
    print("cpu")
' 2>/dev/null || printf 'cpu'
}
select_accelerator() {
  local detected="$1" requested
  echo
  echo "Kubernetes accelerator detection: ${detected^^}"
  if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    echo "Host NVIDIA GPU: accessible"
  else
    echo "Host NVIDIA GPU: not accessible through nvidia-smi (Kubernetes detection takes priority)"
  fi
  read -r -p "Accelerator [auto/cpu/gpu] (auto): " requested
  requested="${requested:-auto}"
  case "$requested" in
    auto) ACCELERATOR="$detected" ;;
    cpu) ACCELERATOR="cpu" ;;
    gpu)
      if [[ "$detected" != "gpu" ]]; then
        echo "ERROR: GPU was requested, but Kubernetes does not advertise an allocatable nvidia.com/gpu resource." >&2
        echo "Configure NVIDIA drivers/container support and the Kubernetes device plugin first." >&2
        return 2
      fi
      ACCELERATOR="gpu"
      ;;
    *) echo "Please enter auto, cpu, or gpu." >&2; return 2 ;;
  esac
  if [[ "$ACCELERATOR" == "gpu" ]]; then
    VLLM_IMAGE="$GPU_IMAGE"
  else
    VLLM_IMAGE="$CPU_IMAGE"
  fi
  export ACCELERATOR VLLM_IMAGE
  echo "Selected accelerator: ${ACCELERATOR^^}"
  echo "Inference image: $VLLM_IMAGE"
}

# Export configured llm_d.env scalar values; already-set process variables win.
while IFS=$'\t' read -r k v; do
  [[ -n "$k" ]] || continue
  [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { echo "ERROR: invalid environment variable name: $k" >&2; exit 2; }
  if [[ ! -v "$k" ]]; then export "$k=$v"; fi
done < <(python3 - "$CONFIG" <<'PYENV'
import sys,yaml
with open(sys.argv[1],encoding='utf-8') as f: d=yaml.safe_load(f) or {}
e=(d.get('llm_d') or {}).get('env') or {}
if not isinstance(e,dict): raise SystemExit('llm_d.env must be a mapping')
for k,v in e.items():
    if isinstance(v,(dict,list)): raise SystemExit(f'llm_d.env.{k} must be scalar')
    s='' if v is None else str(v)
    if any(c in s for c in '\t\r\n'): raise SystemExit(f'llm_d.env.{k} cannot contain tabs/newlines')
    print(f'{k}\t{s}')
PYENV
)
export KUBECONFIG="$KUBECONFIG_PATH" NAMESPACE RELEASE_NAME REPO_ROOT

# Router guide setup is optional and only sourced for router deployment.
need_file() { [[ -f "$1" ]] || { echo "ERROR: required file not found: $1" >&2; exit 2; }; }

# Models selected for sensible vLLM serving paths. Dataset cache entries are not deployable model weights.
MODEL_IDS=(
  'distilgpt2'
  'HuggingFaceTB/SmolLM2-135M'
  'HuggingFaceTB/SmolLM2-360M-Instruct'
  'TinyLlama/TinyLlama-1.1B-Chat-v1.0'
  'LiquidAI/LFM2.5-1.2B-Instruct'
)
MODEL_TYPES=(generation generation generation generation generation)
# requests/limits chosen for a small CPU-only single replica; increase in config if the node has more resources.
MODEL_CPU_REQ=(500m 500m 750m 1 1)
MODEL_CPU_LIM=(2 2 2 3 3)
MODEL_MEM_REQ=(2Gi 1Gi 2Gi 2Gi 3Gi)
MODEL_MEM_LIM=(3Gi 3Gi 4Gi 5Gi 6Gi)

model_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^models--##; s#^datasets--##; s#/#-#g; s#[^a-z0-9.-]+#-#g; s#^-+##; s#-+$##' | cut -c1-48; }

