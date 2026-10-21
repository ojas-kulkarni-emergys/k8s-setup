#!/usr/bin/env bash
set -Eeuo pipefail

# Install and start Tailscale on Ubuntu/Debian.
# Usage: sudo bash setup-tailscale.sh [device-name]
# Example: sudo bash setup-tailscale.sh k8s-worker1

if [[ $EUID -ne 0 ]]; then
  echo "Run with sudo: sudo bash $0 [device-name]" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify this Linux distribution." >&2
  exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" && "${ID:-}" != "debian" && " ${ID_LIKE:-} " != *"debian"* ]]; then
  echo "This script is intended for Ubuntu/Debian." >&2
  exit 1
fi

DEVICE_NAME="${1:-$(hostname -s)}"

sudo apt-get update
sudo apt-get install -y curl ca-certificates
curl -fsSL https://tailscale.com/install.sh | sh

systemctl enable --now tailscaled
echo
echo "Tailscale installed. Starting sign-in for device: ${DEVICE_NAME}"
echo "Open the URL shown below and authorize this machine in your tailnet."
sudo tailscale up --hostname="${DEVICE_NAME}"

echo
echo "Tailscale status:"
sudo tailscale status
echo
echo "This node's Tailscale IPv4 address(es):"
sudo tailscale ip -4
echo
echo "Repeat on the control plane and both workers, using unique device names."
