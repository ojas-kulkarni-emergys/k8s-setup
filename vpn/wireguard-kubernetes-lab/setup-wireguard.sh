#!/usr/bin/env bash
set -Eeuo pipefail

# Install WireGuard and create a protected key pair + config template.
# This does NOT establish a VPN until peer configuration and network reachability
# are configured. Do not share private.key or wg0.conf.
#
# Usage: sudo bash setup-wireguard.sh [control|worker1|worker2]
# Example: sudo bash setup-wireguard.sh control

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0 [control|worker1|worker2]" >&2
  exit 1
fi

ROLE="${1:-}"
case "$ROLE" in
  control) ADDRESS="10.20.0.1/24";;
  worker1) ADDRESS="10.20.0.2/24";;
  worker2) ADDRESS="10.20.0.3/24";;
  *)
    echo "Usage: sudo bash $0 [control|worker1|worker2]" >&2
    echo "Choose a unique role for this machine." >&2
    exit 2
    ;;
esac

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this Linux distribution." >&2
  exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && " ${ID_LIKE:-} " != *"debian"* ]]; then
  echo "This script is intended for Ubuntu/Debian." >&2
  exit 1
fi

sudo apt-get update
sudo apt-get install -y wireguard wireguard-tools

sudo install -d -m 700 /etc/wireguard

if [[ -e /etc/wireguard/private.key || -e /etc/wireguard/public.key ]]; then
  echo "Existing WireGuard key file found; leaving keys unchanged."
else
  sudo umask 077
  sudo wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
  sudo chmod 600 /etc/wireguard/private.key /etc/wireguard/public.key
fi

PRIVATE_KEY="$(cat /etc/wireguard/private.key)"
TEMPLATE="/etc/wireguard/wg0.conf.template"

cat > "$TEMPLATE" <<EOF
# Template only. Add the required [Peer] sections before bringing up wg0.
# Do not share this file: it contains this node's private key.
[Interface]
Address = ${ADDRESS}
PrivateKey = ${PRIVATE_KEY}
# Set ListenPort on the node that will accept inbound WireGuard connections,
# for example: ListenPort = 51820
EOF
chmod 600 "$TEMPLATE"

echo
echo "WireGuard installed and keys generated for role: ${ROLE}"
echo "VPN address planned for this node: ${ADDRESS}"
echo
echo "PUBLIC KEY (safe to share with the other nodes):"
cat /etc/wireguard/public.key
echo
echo "Private key remains in /etc/wireguard/private.key (do not share it)."
echo "Template written to: ${TEMPLATE}"
echo
echo "Next steps:"
echo "  1. Collect each node's public key and decide which node accepts inbound UDP."
echo "  2. Configure peer [Peer] sections, endpoints, AllowedIPs, and firewall rules."
echo "  3. Copy the completed config to /etc/wireguard/wg0.conf (mode 600)."
echo "  4. Test connectivity, then enable with: systemctl enable --now wg-quick@wg0"
echo
echo "This script intentionally does not start WireGuard: the peer/network details"
echo "are environment-specific, and the template is not yet a working VPN config."
