#!/usr/bin/env bash
# Direct commands, independently runnable:
# sudo bash headlamp.sh install [config.yaml]
# sudo bash headlamp.sh forward [config.yaml]
# sudo bash headlamp.sh token [config.yaml]
# sudo bash headlamp.sh logs [config.yaml]
set -Eeuo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
init_config "${2:-}"
headlamp() {
  case "$1" in
    install)
      helm repo add headlamp "$(cfg headlamp.repository)" --force-update
      helm repo update headlamp
      # Temporary Canonical kubeconfig, removed when this subprocess exits.
      (
        kubeconfig="$(mktemp)"
        trap 'rm -f "$kubeconfig"' EXIT
        k8s config > "$kubeconfig"
        helm --kubeconfig "$kubeconfig" upgrade --install "$(cfg headlamp.release)" "$(cfg headlamp.chart)" \
          --namespace "$(cfg headlamp.namespace)" --create-namespace --wait --timeout "$(cfg headlamp.timeout)" \
          -f "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../ingress" && pwd)/headlamp.values.yaml"
      )
      ;;
    forward)
      echo "Open http://127.0.0.1:$(cfg headlamp.local_port)/headlamp/; Ctrl+C stops forwarding."
      k8s kubectl port-forward -n "$(cfg headlamp.namespace)" "service/$(cfg headlamp.release)" \
        "$(cfg headlamp.local_port):$(cfg headlamp.service_port)" --address 127.0.0.1
      ;;
    token)
      k8s kubectl create serviceaccount "$(cfg headlamp.login_service_account)" -n "$(cfg headlamp.namespace)" --dry-run=client -o yaml | k8s kubectl apply -f -
      k8s kubectl create clusterrolebinding "$(cfg headlamp.release)-login" \
        --serviceaccount="$(cfg headlamp.namespace):$(cfg headlamp.login_service_account)" \
        --clusterrole="$(cfg headlamp.login_cluster_role)" --dry-run=client -o yaml | k8s kubectl apply -f -
      # The built-in view role omits nodes. Add only node read permissions.
      k8s kubectl create clusterrole "$(cfg headlamp.release)-node-reader" \
        --verb=get,list,watch --resource=nodes --dry-run=client -o yaml | k8s kubectl apply -f -
      k8s kubectl create clusterrolebinding "$(cfg headlamp.release)-node-reader" \
        --serviceaccount="$(cfg headlamp.namespace):$(cfg headlamp.login_service_account)" \
        --clusterrole="$(cfg headlamp.release)-node-reader" --dry-run=client -o yaml | k8s kubectl apply -f -
      k8s kubectl create token "$(cfg headlamp.login_service_account)" --namespace "$(cfg headlamp.namespace)" --duration=1h
      ;;
    logs)
      k8s kubectl logs -n "$(cfg headlamp.namespace)" -l "app.kubernetes.io/instance=$(cfg headlamp.release)" --all-containers=true --prefix --tail=100
      ;;
    uninstall)
      read -r -p 'Uninstall Headlamp? Type YES: ' answer
      [[ "$answer" == YES ]] || return 0
      (
        kubeconfig="$(mktemp)"
        trap 'rm -f "$kubeconfig"' EXIT
        k8s config > "$kubeconfig"
        helm --kubeconfig "$kubeconfig" uninstall "$(cfg headlamp.release)" -n "$(cfg headlamp.namespace)"
      )
      ;;
    *) echo 'Usage: headlamp.sh [menu|install|forward|token|logs|uninstall] [config.yaml]' >&2; return 2 ;;
  esac
}
if [[ "${1:-install}" != menu ]]; then headlamp "${1:-install}"; exit; fi
while true; do
  printf '\n1) Install / upgrade\n2) Forward localhost:8080\n3) Login token\n4) Logs\n5) Uninstall Headlamp\n0) Back\n'
  read -r -p 'Select: ' choice || exit 0
  case "$choice" in
    1) action=install ;; 2) action=forward ;; 3) action=token ;;
    4) action=logs ;; 5) action=uninstall ;; 0) exit 0 ;; *) continue ;;
  esac
  bash "${BASH_SOURCE[0]}" "$action" "$CONFIG" || echo 'Headlamp action failed.' >&2
done
