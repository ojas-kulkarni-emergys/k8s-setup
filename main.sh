#!/usr/bin/env bash
# Menu orchestrator. Each module can also be run independently with sudo bash.
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$ROOT/config.yaml"
ACTION=''
for arg in "$@"; do
  case "$arg" in --*) ACTION="$arg" ;; *) CONFIG="$arg" ;; esac
done
[[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"
dispatch() {
  case "$1" in
    --configure|--controls|--worker-token|--uninstall|--start-cluster|--stop-cluster|--cluster-status|--install-cluster|--install-control|--install-worker)
      bash "$ROOT/k8s/cluster/node-manager.sh" "$1" "$CONFIG" ;;
    --install-vpn) bash "$ROOT/k8s/cluster/vpn_manager.sh" install "$CONFIG" ;;
    --uninstall-vpn) bash "$ROOT/k8s/cluster/vpn_manager.sh" uninstall "$CONFIG" ;;
    --node-manager) bash "$ROOT/k8s/cluster/node-manager.sh" "$CONFIG" ;;
    --models) bash "$ROOT/k8s/node/llm-d.setup.sh" "$CONFIG" ;;
    --registry) bash "$ROOT/k8s/services/docker-registry.sh" menu "$CONFIG" ;;
    --services) bash "$ROOT/k8s/services/services.sh" "$CONFIG" ;;
    --headlamp) bash "$ROOT/k8s/services/headlamp.sh" menu "$CONFIG" ;;
    --pull-images) bash "$ROOT/k8s/services/pull-cluster-images.sh" ;;
    *) echo "Unknown action: $1" >&2; return 2 ;;
  esac
}
if [[ -n "$ACTION" ]]; then dispatch "$ACTION"; exit; fi
while true; do
  printf '\n=== Kubernetes and LLM manager ===\n1) Node manager\n2) Install VPN\n3) Install Kubernetes (configured role)\n4) Cluster controls / logs\n5) Uninstall\n6) Services (Headlamp / images / registry)\n7) Models / llm-d router\n0) Exit\n'
  read -r -p 'Select: ' choice || exit 0
  case "$choice" in
    1) action=--node-manager ;; 2) action=--install-vpn ;; 3) action=--install-cluster ;;
    4) action=--controls ;; 5) action=--uninstall ;; 6) action=--services ;;
    7) action=--models ;; 0) exit 0 ;; *) echo 'Invalid selection.'; continue ;;
  esac
  dispatch "$action" || echo 'Action failed; review the error above.' >&2
done
