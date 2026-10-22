#!/usr/bin/env bash
# Sourced by ../llm-d.setup.sh; service operations remain Bash commands.
# ---------- llm-d workload management ----------
# These controls scale Deployments rather than deleting resources. Original
# replica counts are stored as annotations so the start action can restore them.
# One classifier and one selection path for every lifecycle action.
workload_action() {
  local action="$1" filter="${2:-all}" json rows name replicas saved kind choice item target
  local -a names=() counts=() originals=() selected=() raw=()
  json="$("${KUBECTL[@]}" get deployments -n "$NAMESPACE" -o json)" || return
  rows="$(python3 -c '
import json,sys
seen=set()
for d in json.load(sys.stdin).get("items",[]):
    m=d.get("metadata",{}); name=m.get("name","")
    cs=d.get("spec",{}).get("template",{}).get("spec",{}).get("containers",[])
    blob=" ".join(str(c.get("image",""))+" "+" ".join(c.get("args",[]) or []) for c in cs).lower()
    component=(m.get("labels",{}) or {}).get("app.kubernetes.io/component","")
    model="vllm" in blob or "--model" in blob or component in ("inference","model-serving")
    router=any(x in name.lower()+" "+blob for x in ("router","gateway","epp","endpoint-picker"))
    kind="model" if model else "router" if router else "other"
    if kind=="other" or name in seen: continue
    seen.add(name)
    saved=(m.get("annotations",{}) or {}).get("llm-d-router-wizard/original-replicas","-")
    print(name,d.get("spec",{}).get("replicas",1),saved,kind,sep="|")
' <<< "$json")" || return
  while IFS='|' read -r name replicas saved kind; do
    [[ -n "$name" && ( "$filter" == all || "$filter" == "$kind" ) ]] || continue
    names+=("$name"); counts+=("$replicas"); originals+=("$saved")
    printf '  %d) %s (%s, replicas=%s)\n' "${#names[@]}" "$name" "$kind" "$replicas"
  done <<< "$rows"
  ((${#names[@]})) || { echo 'No matching deployed workloads.'; return 0; }
  read -r -p "$action: numbers (1,3), A for all, or Enter to cancel: " choice || return
  case "$choice" in
    '') return 0 ;;
    [Aa]) selected=("${!names[@]}") ;;
    *) IFS=',' read -r -a raw <<< "$choice"
       for item in "${raw[@]}"; do
         item="${item//[[:space:]]/}"
         [[ "$item" =~ ^[1-9][0-9]*$ ]] && ((item<=${#names[@]})) || { echo 'Invalid selection.' >&2; return 2; }
         item=$((item-1))
         [[ " ${selected[*]} " == *" $item "* ]] || selected+=("$item")
       done ;;
  esac
  read -r -p "Confirm $action selected workloads? [y/N]: " choice || return
  [[ "$choice" =~ ^[Yy]$ ]] || return 0
  for item in "${selected[@]}"; do
    name="${names[$item]}"; replicas="${counts[$item]}"; saved="${originals[$item]}"
    case "$action" in
      stop)
        [[ "$replicas" != 0 ]] || continue
        "${KUBECTL[@]}" annotate deployment "$name" -n "$NAMESPACE" "llm-d-router-wizard/original-replicas=$replicas" --overwrite || return
        "${KUBECTL[@]}" scale deployment "$name" -n "$NAMESPACE" --replicas=0 || return ;;
      start)
        [[ "$replicas" == 0 ]] || { echo "$name already running ($replicas replicas)."; continue; }
        target="$saved"; [[ "$target" =~ ^[1-9][0-9]*$ ]] || target=1
        "${KUBECTL[@]}" scale deployment "$name" -n "$NAMESPACE" --replicas="$target" || return
        "${KUBECTL[@]}" annotate deployment "$name" -n "$NAMESPACE" llm-d-router-wizard/original-replicas- || return ;;
      delete)
        "${KUBECTL[@]}" delete deployment "$name" -n "$NAMESPACE" --wait=true --timeout=60s || return ;;
    esac
  done
}
stop_llmd() { workload_action stop all; }
start_llmd() { workload_action start router; }
start_model_deployments() { workload_action start model; }
delete_model_deployments() { workload_action delete model; }

forward_units() {
  sudo systemctl list-unit-files 'llm-d-pf-*.service' --no-legend --no-pager | awk '{print $1}'
}
show_background_forwards() {
  local units
  units="$(forward_units)" || return
  [[ -n "$units" ]] || { echo 'No managed forwarding services.'; return 0; }
  while read -r unit; do sudo systemctl status "$unit" --no-pager || true; done <<< "$units"
}
stop_port_forwards() {
  local units unit answer
  units="$(forward_units)" || return
  [[ -n "$units" ]] || { echo 'No managed forwarding services.'; return 0; }
  printf '%s\n' "$units"
  read -r -p 'Disable and stop these forwarding services? [y/N]: ' answer || return
  [[ "$answer" =~ ^[Yy]$ ]] || return 0
  while read -r unit; do sudo systemctl disable --now "$unit" || return; done <<< "$units"
}
forward_logs() {
  local -a units=()
  local i choice
  mapfile -t units < <(forward_units)
  ((${#units[@]})) || { echo 'No forwarding services.'; return 0; }
  for i in "${!units[@]}"; do printf '%d) %s\n' "$((i+1))" "${units[$i]}"; done
  read -r -p 'Service number: ' choice || return
  [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice<=${#units[@]})) || return 2
  sudo journalctl -u "${units[$((choice-1))]}" -n 100 --no-pager
}
workload_logs() {
  local json choice i previous
  local -a pods=() flags=()
  json="$("${KUBECTL[@]}" get pods -n "$NAMESPACE" -o json)" || return
  mapfile -t pods < <(python3 -c 'import json,sys; [print(x["metadata"]["name"]) for x in json.load(sys.stdin).get("items",[])]' <<< "$json")
  ((${#pods[@]})) || { echo 'No pods in this namespace.'; return 0; }
  for i in "${!pods[@]}"; do printf '%d) %s\n' "$((i+1))" "${pods[$i]}"; done
  read -r -p 'Pod number: ' choice || return
  [[ "$choice" =~ ^[1-9][0-9]*$ ]] && ((choice<=${#pods[@]})) || return 2
  read -r -p 'Previous container logs? [y/N]: ' previous || return
  [[ "$previous" =~ ^[Yy]$ ]] && flags+=(--previous)
  "${KUBECTL[@]}" logs "${pods[$((choice-1))]}" -n "$NAMESPACE" --all-containers=true --prefix --tail=100 "${flags[@]}"
}

port_forward_service() {
  local mode="$1" json
  json="$("${KUBECTL[@]}" get services -n "$NAMESPACE" -o json 2>/dev/null)" || { echo "ERROR: cannot list Services in $NAMESPACE." >&2; return 1; }
  local -a options=()
  mapfile -t options < <(python3 -c '
import json,sys
for s in json.load(sys.stdin).get("items",[]):
    md=s.get("metadata",{}); name=md.get("name",""); spec=s.get("spec",{})
    labels=md.get("labels",{}) or {}
    ports=spec.get("ports",[]) or []
    low=name.lower()
    # This headless Service is for model discovery, not a user-facing model API.
    if "model-servers" in low:
        continue
    if any(x in low for x in ("router","gateway","proxy")):
        role="router/client-facing candidate"
    elif "epp" in low:
        role="EPP/internal; not necessarily client-facing"
    elif any(x in low for x in ("backend","vllm","model","distilgpt2","inference")):
        role="model Service"
    else:
        role="Service; verify purpose"
    for p in ports:
        port=p.get("port")
        if port is not None and p.get("protocol", "TCP") == "TCP":
            print(f"{role}\t{name}\t{port}\t{p.get(chr(110)+chr(97)+chr(109)+chr(101), chr(45))}\t{p.get(chr(116)+chr(97)+chr(114)+chr(103)+chr(101)+chr(116)+chr(80)+chr(111)+chr(114)+chr(116), chr(45))}")
' <<<"$json")
  if ((${#options[@]} == 0)); then echo "No likely router/model Services found in $NAMESPACE."; "${KUBECTL[@]}" get services -n "$NAMESPACE"; return 0; fi
  echo 'Detected Service ports (choose a router/client endpoint or a model Service):'
  local i role service remote portname target selection local_port answer safe base pid log
  for i in "${!options[@]}"; do IFS=$'\t' read -r role service remote portname target <<< "${options[$i]}"; printf '  %2d) %-37s %-29s port=%-5s targetPort=%s\n' "$((i+1))" "$service" "$role" "$remote" "$target"; done
  read -r -p 'Choose Service port number: ' selection
  [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#options[@]} )) || { echo 'Invalid selection.' >&2; return 2; }
  IFS=$'\t' read -r role service remote portname target <<< "${options[$((selection-1))]}"
  if [[ "$role" == *'EPP/internal'* || "$role" == *'internal'* ]]; then
    echo "WARNING: $service is marked '$role'. It may not be the client-facing inference endpoint."
  fi
  read -r -p "Local port [$remote]: " local_port; local_port="${local_port:-$remote}"
  [[ "$local_port" =~ ^[0-9]+$ ]] && (( local_port >= 1 && local_port <= 65535 )) || { echo 'Local port must be 1-65535.' >&2; return 2; }
  if [[ "$mode" == 'foreground' ]]; then
    echo "Forwarding http://127.0.0.1:$local_port to Service/$service:$remote. Press Ctrl+C to stop."
    "${KUBECTL[@]}" port-forward --address 127.0.0.1 -n "$NAMESPACE" "service/$service" "$local_port:$remote"
    return $?
  fi
  # A persistent systemd service owns kubectl and restarts it when a pod exits.
  sudo -v || return
  command -v systemctl >/dev/null || { echo 'systemd is required for background forwards.' >&2; return 1; }
  local unit k8s_bin temp
  k8s_bin="$(command -v k8s)" || { echo 'k8s executable not found.' >&2; return 1; }
  unit="llm-d-pf-$(printf '%s' "$CONFIG|$NAMESPACE|$service|$remote|$local_port" | sha256sum | cut -c1-20).service"
  temp="$(mktemp)" || return
  python3 - "$temp" "$unit" "$k8s_bin" "$NAMESPACE" "$service" "$local_port:$remote" <<'PYUNIT'
import sys
path,unit,binary,namespace,service,ports=sys.argv[1:]
def quote(s):
    return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('%','%%').replace('$','$$').replace('\n','\\n').replace('\r','\\r')+'"'
command=[binary,'kubectl','port-forward','--address','127.0.0.1','-n',namespace,'service/'+service,ports]
with open(path,'w') as f:
    f.write('[Unit]\nDescription=llm-d port forward '+unit+'\nWants=network-online.target\nAfter=network-online.target\nStartLimitIntervalSec=0\n\n[Service]\nType=simple\nExecStart='+ ' '.join(map(quote,command))+'\nRestart=always\nRestartSec=5\nStandardOutput=journal\nStandardError=journal\n\n[Install]\nWantedBy=multi-user.target\n')
PYUNIT
  sudo install -m 644 "$temp" "/etc/systemd/system/$unit" || { rm -f "$temp"; return 1; }
  rm -f "$temp"
  sudo systemctl daemon-reload || return
  sudo systemctl enable "$unit" || return
  sudo systemctl restart "$unit" || return
  sleep 2
  sudo systemctl status "$unit" --no-pager || return
  sudo journalctl -u "$unit" -n 15 --no-pager || return
  echo "Forward service: $unit (restarts automatically, enabled at boot)"
  echo "Endpoint: http://127.0.0.1:$local_port; inspect connection errors in Port forwarding > Logs."
}


connect_model_to_pool() {
  local json
  local -a deployments=() pools=()
  json="$("${KUBECTL[@]}" get deployments -n "$NAMESPACE" -o json 2>/dev/null)" || { echo "ERROR: cannot list Deployments in $NAMESPACE." >&2; return 1; }
  mapfile -t deployments < <(python3 -c '
import json,sys
for d in json.load(sys.stdin).get("items",[]):
    md=d.get("metadata",{}); name=md.get("name",""); spec=d.get("spec",{}).get("template",{}).get("spec",{})
    blob=(name+" "+" ".join(str(c.get("image",""))+" "+" ".join(map(str,c.get("args",[]))) for c in spec.get("containers",[]))).lower()
    if "vllm" in blob or "--model" in blob or name.startswith("hf-") or "distilgpt2" in blob or "inference" in name: print(name)
' <<<"$json")
  ((${#deployments[@]})) || { echo 'No model-serving Deployments found.'; return 0; }
  echo 'Model-serving Deployments:'
  local i
  for i in "${!deployments[@]}"; do printf '  %d) %s\n' "$((i+1))" "${deployments[$i]}"; done
  local selection deployment
  read -r -p 'Choose Deployment number: ' selection
  [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#deployments[@]} )) || { echo 'Invalid selection.' >&2; return 2; }
  deployment="${deployments[$((selection-1))]}"
  local label_key label_value
  label_key='app.kubernetes.io/name'
  label_value="$("${KUBECTL[@]}" get deployment "$deployment" -n "$NAMESPACE" -o json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("spec",{}).get("template",{}).get("metadata",{}).get("labels",{}) or {}).get("app.kubernetes.io/name", ""))' 2>/dev/null || true)"
  if [[ -z "$label_value" ]]; then
    echo "Deployment/$deployment has no pod label '$label_key'. Cannot safely select it." >&2; return 2
  fi
  mapfile -t pools < <("${KUBECTL[@]}" get inferencepool -n "$NAMESPACE" -o json 2>/dev/null | python3 -c 'import json,sys; [print(x.get("metadata",{}).get("name","")) for x in json.load(sys.stdin).get("items",[])]' 2>/dev/null || true)
  ((${#pools[@]})) || { echo "No InferencePool resources found in $NAMESPACE."; return 1; }
  echo 'InferencePools:'
  for i in "${!pools[@]}"; do printf '  %d) %s\n' "$((i+1))" "${pools[$i]}"; done
  local pool_choice pool
  read -r -p 'Choose InferencePool number: ' pool_choice
  [[ "$pool_choice" =~ ^[0-9]+$ ]] && (( pool_choice >= 1 && pool_choice <= ${#pools[@]} )) || { echo 'Invalid selection.' >&2; return 2; }
  pool="${pools[$((pool_choice-1))]}"
  echo "This will replace InferencePool/$pool's current selector with $label_key=$label_value."
  read -r -p 'Proceed? [y/N]: ' answer
  [[ "${answer:-}" =~ ^[Yy]$ ]] || { echo 'Pool update cancelled.'; return 0; }
  "${KUBECTL[@]}" patch inferencepool "$pool" -n "$NAMESPACE" --type=merge -p "{\"spec\":{\"selector\":{\"matchLabels\":{\"$label_key\":\"$label_value\"}}}}"
  echo 'Pool selector updated. This does not create a Gateway or HTTPRoute.'
  echo 'Check routing resources with: sudo k8s kubectl get gateway,httproute -A'
}


workload_menu() {
  local choice
  while true; do
    echo
    echo '---------------- Workloads ----------------'
    echo '  1) Stop workloads'
    echo '  2) Delete model(s)'
    echo '  3) Start router'
    echo '  4) Start model(s)'
    echo '  5) View logs'
    echo '  0) Back'
    read -r -p 'Select [0-5]: ' choice || return 0
    case "${choice:-}" in
      1) stop_llmd ;;
      2) delete_model_deployments ;;
      3) start_llmd ;;
      4) start_model_deployments ;;
      5) workload_logs ;;
      0) return 0 ;;
      *) echo 'Invalid selection; choose 1-5.' ;;
    esac
  done
}

port_forward_menu() {
  local choice
  while true; do
    echo
    echo '------------- Port Forwarding -------------'
    echo '  1) Start background forward (router or model Service)'
    echo '  2) Start foreground forward'
    echo '  3) Show background forwards'
    echo '  4) Stop background forwards'
    echo '  5) View logs'
    echo '  0) Back'
    read -r -p 'Select [0-5]: ' choice || return 0
    case "${choice:-}" in
      1) port_forward_service background ;;
      2) port_forward_service foreground ;;
      3) show_background_forwards ;;
      4) stop_port_forwards ;;
      5) forward_logs ;;
      0) return 0 ;;
      *) echo 'Invalid selection; choose 1-5.' ;;
    esac
  done
}

management_menu() {
  local management_choice
  while true; do
    echo
    echo '================================================'
    echo '              llm-d Setup Menu'
    echo '================================================'
    echo "Namespace: $NAMESPACE"
    echo '  1) Deploy / configure'
    echo '  2) Connect model to InferencePool'
    echo '  3) Manage workloads'
    echo '  4) Port forwarding'
    echo '  5) Exit'
    read -r -p 'Select [1-5]: ' management_choice || return 1
    case "${management_choice:-}" in
      1) return 0 ;;
      2) connect_model_to_pool ;;
      3) workload_menu ;;
      4) port_forward_menu ;;
      5) exit 0 ;;
      *) echo 'Invalid selection; choose 1-5.' ;;
    esac
  done
}
# ---------- end llm-d workload management ----------

