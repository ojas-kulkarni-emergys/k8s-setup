#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# One entry point for Canonical Kubernetes + optional VPN.
# Run on each machine after editing config.yml for that machine:
#   sudo ./setup-cluster.sh [path/to/config.yml]
#
# Requires Ubuntu, systemd, snapd, Python 3 and PyYAML (the script installs
# python3-yaml if needed). VPN credentials and join tokens are secrets.

CONFIG="${1:-./config.yml}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
[[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo $0 [path/to/config.yml]" >&2
  exit 1
fi
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 2; }
[[ -r /etc/os-release ]] || { echo "Cannot identify Linux distribution." >&2; exit 1; }
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || { echo "Ubuntu is required (detected ${ID:-unknown})." >&2; exit 1; }

# Read YAML safely using Python/PyYAML. Install parser if absent.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y python3-yaml
fi

cfg() {
  python3 - "$CONFIG" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}
for part in sys.argv[2].split("."):
    if not isinstance(d, dict) or part not in d:
        d = None
        break
    d = d[part]
if d is None:
    print("")
elif isinstance(d, bool):
    print("true" if d else "false")
elif isinstance(d, (dict, list)):
    print(yaml.safe_dump(d, default_flow_style=True).strip())
else:
    print(str(d))
PY
}

ROLE="${SETUP_ROLE_OVERRIDE:-$(cfg role)}"
NODE_NAME="$(cfg node_name)"
VPN="$(cfg vpn)"
CHANNEL="$(cfg kubernetes.channel)"
NODE_ADDRESS="$(cfg kubernetes.node_address)"
JOIN_TOKEN="$(cfg kubernetes.join_token)"
VPN_DIR="$(cfg paths.vpn_dir)"
ADDONS="$(cfg kubernetes.addons)"
TAILSCALE_SCRIPT="$(cfg paths.tailscale_script)"
OPENVPN_SCRIPT="$(cfg paths.openvpn_script)"
WG_CONFIG="$(cfg paths.wireguard_config)"
OPENVPN_BUNDLE="$(cfg paths.openvpn_client_bundle)"
OPENVPN_ENDPOINT="$(cfg openvpn.endpoint)"
OPENVPN_CLIENT_NAME="$(cfg openvpn.client_name)"

[[ "$ROLE" == "control" || "$ROLE" == "worker" ]] || { echo "config.yml: role must be control or worker." >&2; exit 2; }
[[ -n "$NODE_NAME" ]] || { echo "config.yml: node_name is required." >&2; exit 2; }
[[ "$VPN" == "none" || "$VPN" == "tailscale" || "$VPN" == "wireguard" || "$VPN" == "openvpn" ]] || {
  echo "config.yml: vpn must be none, tailscale, wireguard, or openvpn." >&2; exit 2;
}
[[ -n "$CHANNEL" ]] || CHANNEL="1.35-classic/stable"
[[ -n "$OPENVPN_CLIENT_NAME" ]] || OPENVPN_CLIENT_NAME="${NODE_NAME#k8s-}"
[[ -n "$VPN_DIR" ]] || VPN_DIR="$SCRIPT_DIR/vpn"
[[ -n "$TAILSCALE_SCRIPT" ]] || TAILSCALE_SCRIPT="$VPN_DIR/tailscale-kubernetes-lab/setup-tailscale.sh"
[[ -n "$OPENVPN_SCRIPT" ]] || OPENVPN_SCRIPT="$VPN_DIR/openvpn-kubernetes-lab/setup-openvpn.sh"

resolve_path() {
  local p="$1"
  [[ -z "$p" ]] && { echo ""; return; }
  [[ "$p" = /* ]] && echo "$p" || echo "$SCRIPT_DIR/$p"
}
TAILSCALE_SCRIPT="$(resolve_path "$TAILSCALE_SCRIPT")"
OPENVPN_SCRIPT="$(resolve_path "$OPENVPN_SCRIPT")"
WG_CONFIG="$(resolve_path "$WG_CONFIG")"
OPENVPN_BUNDLE="$(resolve_path "$OPENVPN_BUNDLE")"

echo "== Canonical Kubernetes node setup =="
echo "Role: $ROLE | Name: $NODE_NAME | VPN: $VPN | Channel: $CHANNEL"
hostnamectl set-hostname "$NODE_NAME"

# --- VPN setup first, so Kubernetes can use the selected node address. ---
case "$VPN" in
  none)
    if [[ "$NODE_ADDRESS" == "auto" || -z "$NODE_ADDRESS" ]]; then
      echo "For vpn: none, set kubernetes.node_address to a reachable node IP in config.yml." >&2
      exit 2
    fi
    ;;
  tailscale)
    [[ -f "$TAILSCALE_SCRIPT" ]] || { echo "Tailscale script not found: $TAILSCALE_SCRIPT" >&2; exit 1; }
    bash "$TAILSCALE_SCRIPT" "$NODE_NAME"
    NODE_ADDRESS="$(tailscale ip -4 | head -n1 || true)"
    [[ -n "$NODE_ADDRESS" ]] || { echo "No Tailscale IPv4 found; authenticate this node and retry." >&2; exit 1; }
    ;;
  wireguard)
    if [[ ! -f "$WG_CONFIG" ]]; then
      echo "WireGuard needs a completed peer config. Set paths.wireguard_config to a valid wg0.conf." >&2
      echo "The bundled setup-wireguard.sh only creates keys/templates; it cannot configure peers automatically." >&2
      exit 2
    fi
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard wireguard-tools
    install -d -m 700 /etc/wireguard
    install -m 600 "$WG_CONFIG" /etc/wireguard/wg0.conf
    systemctl enable --now wg-quick@wg0
    for _ in $(seq 1 30); do
      ip link show wg0 >/dev/null 2>&1 && break
      sleep 2
    done
    WG_ADDR="$(ip -o -4 addr show dev wg0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
    [[ -n "$WG_ADDR" ]] || { echo "wg0 is not up or has no IPv4 address." >&2; exit 1; }
    NODE_ADDRESS="$WG_ADDR"
    ;;
  openvpn)
    if [[ "$ROLE" == "control" ]]; then
      [[ -n "$OPENVPN_ENDPOINT" ]] || { echo "Set openvpn.endpoint to the server's reachable public IPv4/DNS in config.yml." >&2; exit 2; }
      [[ -f "$OPENVPN_SCRIPT" ]] || { echo "OpenVPN server script not found: $OPENVPN_SCRIPT" >&2; exit 1; }
      bash "$OPENVPN_SCRIPT" "$OPENVPN_ENDPOINT"
      for _ in $(seq 1 30); do
        ip link show tun0 >/dev/null 2>&1 && break
        sleep 2
      done
      NODE_ADDRESS="$(ip -o -4 addr show dev tun0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
      [[ -n "$NODE_ADDRESS" ]] || NODE_ADDRESS="10.8.0.1"
    else
      [[ -f "$OPENVPN_BUNDLE" ]] || { echo "Worker OpenVPN bundle not found: $OPENVPN_BUNDLE. Securely copy this worker's archive from the control plane." >&2; exit 2; }
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn
      install -d -m 700 /etc/openvpn/client
      tar -xzf "$OPENVPN_BUNDLE" -C /etc/openvpn/client
      install -d -m 700 "/etc/openvpn/client"
      [[ "$OPENVPN_CLIENT_NAME" =~ ^[A-Za-z0-9_-]+$ ]] || { echo "openvpn.client_name must contain only letters, digits, underscore, or hyphen." >&2; exit 2; }
      [[ -f "/etc/openvpn/client/${OPENVPN_CLIENT_NAME}.conf" ]] || { echo "Expected client config missing: /etc/openvpn/client/${OPENVPN_CLIENT_NAME}.conf" >&2; exit 1; }
      chmod 600 "/etc/openvpn/client/${OPENVPN_CLIENT_NAME}.conf"
      chmod 600 "/etc/openvpn/client/${OPENVPN_CLIENT_NAME}/${OPENVPN_CLIENT_NAME}.key" "/etc/openvpn/client/${OPENVPN_CLIENT_NAME}/ta.key"
      systemctl enable --now "openvpn-client@${OPENVPN_CLIENT_NAME}"
      for _ in $(seq 1 30); do
        ip link show tun0 >/dev/null 2>&1 && break
        sleep 2
      done
      VPN_ADDR="$(ip -o -4 addr show dev tun0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
      [[ -n "$VPN_ADDR" ]] || { echo "OpenVPN tun0 did not acquire an IPv4 address; check openvpn-client@${OPENVPN_CLIENT_NAME}." >&2; exit 1; }
      NODE_ADDRESS="$VPN_ADDR"
    fi
    ;;
esac

# Persist the resolved node address in this node's config.yml so the file
# reflects the address actually used for bootstrap/join.
if [[ "$NODE_ADDRESS" != "auto" && -n "$NODE_ADDRESS" ]]; then
  python3 - "$CONFIG" "$NODE_ADDRESS" <<'PY'
import sys, yaml
path, address = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
data.setdefault("kubernetes", {})["node_address"] = address
with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(data, f, sort_keys=False, default_flow_style=False, allow_unicode=True)
PY
fi

echo "Node address selected and saved to config.yml: $NODE_ADDRESS"
echo "VPN interfaces:"
ip -br addr || true

# --- Canonical Kubernetes install/bootstrap/join. ---
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

if [[ "$ROLE" == "control" ]]; then
  if k8s kubectl get nodes >/dev/null 2>&1; then
    echo "A Kubernetes cluster is already responding; skipping bootstrap."
  else
    echo "Initiating Kubernetes bootstrap..."
    # Run bootstrap and capture output/exit code
    BOOTSTRAP_OUTPUT=$(k8s bootstrap --name="$NODE_NAME" --address="$NODE_ADDRESS" 2>&1)
    BOOTSTRAP_EXIT=$?

    # If it failed due to the specific containerd path conflict, clean and retry once
    if [ $BOOTSTRAP_EXIT -ne 0 ] && echo "$BOOTSTRAP_OUTPUT" | grep -q "The path '/run/containerd' required for the containerd socket already exists"; then
      echo "Detected conflicting /run/containerd path. Cleaning up and retrying bootstrap..."
      sudo rm -rf /run/containerd
      sudo k8s bootstrap --name="$NODE_NAME" --address="$NODE_ADDRESS"
    # If it failed due to microcluster database initialization timeout, reset state and retry
    elif [ $BOOTSTRAP_EXIT -ne 0 ] && echo "$BOOTSTRAP_OUTPUT" | grep -q "context deadline exceeded"; then
      echo "Detected daemon initialization timeout. Resetting uninitialized database state and retrying..."
      sudo systemctl stop snap.k8s.k8sd
      sudo rm -rf /var/snap/k8s/common/var/lib/k8sd/state/*
      sudo rm -rf /run/containerd
      sudo systemctl start snap.k8s.k8sd
      sleep 3
      sudo k8s bootstrap --name="$NODE_NAME" --address="$NODE_ADDRESS"
    elif [ $BOOTSTRAP_EXIT -ne 0 ]; then
      # If it failed for a different error, print the output and exit
      echo "$BOOTSTRAP_OUTPUT"
      exit $BOOTSTRAP_EXIT
    fi
  fi
  
  sudo k8s status --wait-ready --timeout 5m
  echo
  echo "Control plane ready. To generate worker tokens, run on this control plane:"
  echo "  sudo k8s get-join-token k8s-worker1 --worker"
  echo "  sudo k8s get-join-token k8s-worker2 --worker"
  echo "  sudo k8s get-join-token <WORKER_NAME> --worker"
  echo "Copy each token securely into that worker's config.yml (kubernetes.join_token)."

else
  [[ -n "$JOIN_TOKEN" ]] || { echo "Worker config needs kubernetes.join_token from the control plane." >&2; exit 2; }
  if sudo k8s kubectl get nodes >/dev/null 2>&1; then
    echo "This node already has access to a Kubernetes cluster; skipping join."
  else
    sudo k8s join-cluster "$JOIN_TOKEN" --name="$NODE_NAME" --address="$NODE_ADDRESS"
  fi
  sudo k8s status || true
fi

# Optional addons are enabled only on the control plane, after bootstrap.
if [[ "$ROLE" == "control" && -n "$ADDONS" && "$ADDONS" != "[]" && "$ADDONS" != "null" ]]; then
  echo "Enabling configured addons: $ADDONS"
  python3 - "$CONFIG" <<'PY' | while IFS= read -r addon; do
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    d=yaml.safe_load(f) or {}
for a in (d.get("kubernetes", {}).get("addons", []) or []):
    print(a)
PY
    if [[ -n "$addon" ]]; then
      echo "Enabling addon: $addon..."
      sudo k8s enable "$addon"
      ADDON_EXIT=$?
      
      # If addon enablement fails (common with webhooks in WSL2), restart daemon and retry once
      if [ $ADDON_EXIT -ne 0 ]; then
        echo "Addon '$addon' failed on first attempt. Restarting k8s daemon to clear transient webhook timeouts and retrying..."
        sudo systemctl restart snap.k8s.k8sd
        sleep 10
        sudo k8s enable "$addon" || {
          echo "Error: Addon '$addon' failed to enable even after daemon restart." >&2
          exit 1
        }
      fi
    fi
  done
fi

echo
echo "Setup step completed. Verify from the control plane:"
echo "  sudo k8s kubectl get nodes -o wide"
echo "  sudo k8s status"
echo
echo "Note: VPN connectivity does not automatically guarantee pod/CNI routing."
echo "Verify the installed Canonical Kubernetes version's supported address options and CNI routes."
