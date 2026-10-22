#!/usr/bin/env bash
# sudo bash docker-registry.sh [menu|apply|status|logs|forward|manage] [config.yaml]
# Literal equivalent: sudo k8s kubectl apply -f /home/ojas/hf/k8s-setup/k8s/node/docker-registry.yaml
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
init_config "${2:-}"
case "${1:-menu}" in
  menu)
    if k8s kubectl get deployment "$(cfg registry.deployment)" -n "$(cfg registry.namespace)" >/dev/null 2>&1; then
      echo 'Registry already installed; choose Manage to inspect its contents.'
    else
      echo 'Registry deployment not found or API unavailable; choose Install / apply to install.'
    fi
    while true; do
      printf '\n=== Docker registry ===\n1) Install / apply manifest\n2) Manage repositories / tags / deletion / GC preview\n3) Status / PVC\n4) Logs\n5) Forward localhost port (leave running for API management)\n0) Back\n'
      read -r -p 'Select: ' choice || exit 0
      case "$choice" in
        1) action=apply ;; 2) action=manage ;; 3) action=status ;;
        4) action=logs ;; 5) action=forward ;; 0) exit 0 ;; *) continue ;;
      esac
      bash "${BASH_SOURCE[0]}" "$action" "$CONFIG" || echo 'Registry action failed.' >&2
    done
    ;;
  manage)
    exec bash "$(dirname -- "${BASH_SOURCE[0]}")/../node/registry_manager.sh" menu --config "$CONFIG"
    ;;
  forward)
    echo "Registry URL: $(cfg registry.url). Leave this running; manage in another terminal."
    k8s kubectl port-forward -n "$(cfg registry.namespace)" "service/$(cfg registry.service)" \
      "$(cfg registry.local_port):$(cfg registry.service_port)" --address 127.0.0.1
    ;;
  apply)
    k8s kubectl apply -f "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../node" && pwd)/docker-registry.yaml"
    echo 'Manifest applied. Check status for pod readiness and PVC provisioning.'
    ;;
  status)
    k8s kubectl get deployments,pods,services,pvc -n "$(cfg registry.namespace)" -o wide
    ;;
  logs)
    k8s kubectl logs -n "$(cfg registry.namespace)" "deployment/$(cfg registry.deployment)" --all-containers=true --tail=100 --prefix
    ;;
  *) echo 'Usage: docker-registry.sh [apply|status|logs] [config.yaml]' >&2; exit 2 ;;
esac
