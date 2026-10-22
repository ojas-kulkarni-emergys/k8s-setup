#!/usr/bin/env bash
# Usage: sudo bash setup-worker.sh [config.yaml]
set -Eeuo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"

prepare_node() {
  init_config "${1:-}"
  [[ "$(cfg role)" == "$2" ]] || { echo "Config role must be $2." >&2; return 2; }
  NODE_NAME="$(cfg node_name)"
  [[ "$NODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo 'Invalid node name.' >&2; return 2; }
  CHANNEL="$(cfg kubernetes.channel)"
  [[ -n "$CHANNEL" ]] || { echo 'Set kubernetes.channel.' >&2; return 2; }
  NODE_ADDRESS="$(bash "$(dirname -- "${BASH_SOURCE[0]}")/vpn_manager.sh" address "$CONFIG")"
  python3 - "$CONFIG" "$NODE_ADDRESS" <<'PYSAVE'
import sys,yaml
with open(sys.argv[1]) as f: data=yaml.safe_load(f)
data.setdefault('kubernetes',{})['node_address']=sys.argv[2]
with open(sys.argv[1],'w') as f: yaml.safe_dump(data,f,sort_keys=False)
PYSAVE
  hostnamectl set-hostname "$NODE_NAME"
  if ! command -v snap >/dev/null 2>&1; then
    echo "snapd is required. Install/enable snapd, then rerun." >&2
    exit 1
  fi
  if ! snap list k8s >/dev/null 2>&1; then
    snap install k8s --classic --channel="$CHANNEL"
  else
    INSTALLED="$(snap list k8s | awk 'NR==2 {print $2}')"
    echo "Canonical Kubernetes snap already installed (revision version: ${INSTALLED:-unknown}); not reinstalling."
  fi

}
recover_images() {
  if [[ "$(cfg image_recovery.enabled)" == true ]]; then
    bash "$(dirname -- "${BASH_SOURCE[0]}")/../services/pull-cluster-images.sh"
  else
    echo 'Image recovery disabled in config.yaml.'
  fi
}

init_config "${1:-}"
JOIN_TOKEN="$(cfg kubernetes.join_token)"
[[ -n "$JOIN_TOKEN" ]] || { echo 'Configure the worker join token first.' >&2; exit 2; }
prepare_node "$CONFIG" worker
if k8s kubectl get nodes >/dev/null 2>&1; then
  echo "This node already has access to a Kubernetes cluster; skipping join."
else
  k8s join-cluster "$JOIN_TOKEN" --name="$NODE_NAME" --address="$NODE_ADDRESS"
fi
recover_images
k8s status || true
