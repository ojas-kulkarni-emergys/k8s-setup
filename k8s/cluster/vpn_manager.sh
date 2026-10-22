#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
# Usage: sudo bash vpn_manager.sh install|uninstall|address [config.yaml]
init_config "${2:-}"
ROLE="$(cfg role)"
NODE_NAME="$(cfg node_name)"
VPN="$(cfg vpn)"
NODE_ADDRESS="$(cfg kubernetes.node_address)"
VPN_DIR="$(cfg paths.vpn_dir)"
TAILSCALE_SCRIPT="$(cfg paths.tailscale_script)"
OPENVPN_SCRIPT="$(cfg paths.openvpn_script)"
WG_CONFIG="$(cfg paths.wireguard_config)"
OPENVPN_BUNDLE="$(cfg paths.openvpn_client_bundle)"
OPENVPN_ENDPOINT="$(cfg openvpn.endpoint)"
OPENVPN_CLIENT_NAME="$(cfg openvpn.client_name)"

[[ "$ROLE" == "control" || "$ROLE" == "worker" ]] || { echo "config.yaml: role must be control or worker." >&2; exit 2; }
[[ "$NODE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "config.yaml: node_name is required." >&2; exit 2; }
[[ "$VPN" == "none" || "$VPN" == "tailscale" || "$VPN" == "wireguard" || "$VPN" == "openvpn" ]] || {
  echo "config.yaml: vpn must be none, tailscale, wireguard, or openvpn." >&2; exit 2;
}
[[ -n "$OPENVPN_CLIENT_NAME" ]] || OPENVPN_CLIENT_NAME="${NODE_NAME#k8s-}"
[[ -n "$VPN_DIR" ]] || VPN_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)/vpn"
[[ "$VPN_DIR" = /* ]] || VPN_DIR="$CONFIG_DIR/$VPN_DIR"
[[ -n "$TAILSCALE_SCRIPT" ]] || TAILSCALE_SCRIPT="$VPN_DIR/tailscale-kubernetes-lab/setup-tailscale.sh"
[[ -n "$OPENVPN_SCRIPT" ]] || OPENVPN_SCRIPT="$VPN_DIR/openvpn-kubernetes-lab/setup-openvpn.sh"

resolve_path() {
  local p="$1"
  [[ -z "$p" ]] && { echo ""; return; }
  [[ "$p" = /* ]] && echo "$p" || echo "$CONFIG_DIR/$p"
}
TAILSCALE_SCRIPT="$(resolve_path "$TAILSCALE_SCRIPT")"
OPENVPN_SCRIPT="$(resolve_path "$OPENVPN_SCRIPT")"
WG_CONFIG="$(resolve_path "$WG_CONFIG")"
OPENVPN_BUNDLE="$(resolve_path "$OPENVPN_BUNDLE")"

case "${1:-}" in
  install)
case "$VPN" in
  none)
    if [[ "$NODE_ADDRESS" == "auto" || -z "$NODE_ADDRESS" ]]; then
      echo "For vpn: none, set kubernetes.node_address to a reachable node IP in config.yaml." >&2
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
      [[ -n "$OPENVPN_ENDPOINT" ]] || { echo "Set openvpn.endpoint to the server's reachable public IPv4/DNS in config.yaml." >&2; exit 2; }
      [[ -f "$OPENVPN_SCRIPT" ]] || { echo "OpenVPN server script not found: $OPENVPN_SCRIPT" >&2; exit 1; }
      if [[ -f /etc/openvpn/server/server.conf ]]; then
        systemctl enable --now openvpn-server@server
      else
        bash "$OPENVPN_SCRIPT" "$OPENVPN_ENDPOINT"
      fi
      for _ in $(seq 1 30); do
        ip link show tun0 >/dev/null 2>&1 && break
        sleep 2
      done
      NODE_ADDRESS="$(ip -o -4 addr show dev tun0 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')"
      [[ -n "$NODE_ADDRESS" ]] || { echo "OpenVPN tun0 has no IPv4 address." >&2; exit 1; }
    else
      [[ -f "$OPENVPN_BUNDLE" ]] || { echo "Worker OpenVPN bundle not found: $OPENVPN_BUNDLE. Securely copy this worker's archive from the control plane." >&2; exit 2; }
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn
      install -d -m 700 /etc/openvpn/client
      python3 - "$OPENVPN_BUNDLE" "$OPENVPN_CLIENT_NAME" <<'PYTAR'
import sys, tarfile
from pathlib import PurePosixPath
archive, client = sys.argv[1:]
if not client or any(c not in 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-' for c in client):
    raise SystemExit('Invalid OpenVPN client name')
with tarfile.open(archive, 'r:gz') as tar:
    for member in tar.getmembers():
        path = PurePosixPath(member.name)
        if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
            raise SystemExit('Unsafe OpenVPN archive member')
        if path.parts and path.parts[0] not in (client, client + '.conf'):
            raise SystemExit('Unexpected OpenVPN archive contents')
    tar.extractall('/etc/openvpn/client', filter='data')
PYTAR
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

[[ -n "$NODE_ADDRESS" && "$NODE_ADDRESS" != auto ]] || { echo 'No node address. Install/connect VPN first or configure a reachable node IP.' >&2; exit 2; }

# Persist the resolved node address in this node's config.yaml so the file
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

    echo 'VPN installation complete.'
    ;;
  address)
    if [[ "$VPN" != none ]]; then
  case "$VPN" in
    tailscale) NODE_ADDRESS="$(tailscale ip -4)"; NODE_ADDRESS="${NODE_ADDRESS%%$'\n'*}" ;;
    wireguard) NODE_ADDRESS="$(ip -o -4 addr show dev wg0 | awk '{split($4,a,"/"); print a[1]; exit}')" ;;
    openvpn) NODE_ADDRESS="$(ip -o -4 addr show dev tun0 | awk '{split($4,a,"/"); print a[1]; exit}')" ;;
  esac
    fi
    [[ -n "$NODE_ADDRESS" && "$NODE_ADDRESS" != auto ]] || { echo 'No active node IP. Connect VPN first.' >&2; exit 1; }
    printf '%s\n' "$NODE_ADDRESS"
    ;;
  uninstall)
    echo "Remove configured VPN '$VPN' from $NODE_NAME. This may disconnect this node."
    read -r -p "Type '$NODE_NAME' to confirm: " answer
    [[ "$answer" == "$NODE_NAME" ]] || { echo 'Cancelled.'; exit 0; }
    case "$VPN" in
        none)
            echo "No VPN selected; skipping VPN cleanup."
            ;;

        tailscale)
            if command -v tailscale >/dev/null 2>&1; then
                tailscale logout || true
            fi

            systemctl disable --now tailscaled 2>/dev/null || true

            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get purge -y tailscale || true
            fi

            echo "Tailscale state was retained unless removed by its package scripts."
            ;;

        wireguard)
            systemctl disable --now wg-quick@wg0 2>/dev/null || true

            # Remove only the configured interface file used by this setup.
            rm -f /etc/wireguard/wg0.conf
            rmdir /etc/wireguard 2>/dev/null || true

            if command -v apt-get >/dev/null 2>&1; then
                DEBIAN_FRONTEND=noninteractive apt-get purge -y wireguard wireguard-tools || true
            fi

            echo "Other WireGuard configuration files were not intentionally removed."
            ;;

        openvpn)
            if [[ "$ROLE" == "control" ]]; then
                systemctl disable --now openvpn-server@server 2>/dev/null || true

                # These are common paths; confirm they match your setup scripts.
                rm -rf /etc/openvpn/server /etc/openvpn/easy-rsa /root/openvpn-clients

                if command -v apt-get >/dev/null 2>&1; then
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y openvpn easy-rsa || true
                fi

                echo "Review firewall rules and remove any lab-specific OpenVPN rules manually."
            else
                if [[ "$OPENVPN_CLIENT_NAME" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    systemctl disable --now "openvpn-client@${OPENVPN_CLIENT_NAME}" 2>/dev/null || true
                    rm -f "/etc/openvpn/client/${OPENVPN_CLIENT_NAME}.conf"
                    rm -rf "/etc/openvpn/client/${OPENVPN_CLIENT_NAME}"
                else
                    echo "WARNING: unsafe client name; skipped client-file cleanup."
                fi

                if command -v apt-get >/dev/null 2>&1; then
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y openvpn || true
                fi
            fi
            ;;
    esac

    ;;
  *) echo 'Usage: vpn_manager.sh install|uninstall|address [config.yaml]' >&2; exit 2 ;;
esac
