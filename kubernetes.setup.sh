#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
echo "kubernetes.setup.sh now delegates to the unified config-driven setup."
echo "Edit $DIR/config.yml and select role: control or role: worker."
exec "$DIR/setup-cluster.sh" "${1:-$DIR/config.yml}"

# sudo hostnamectl set-hostname RACIT026 #(k8s-control-plane)
# ping -c 3 192.168.1.10
# # --- 192.168.1.10 ping statistics ---
# # 2 packets transmitted, 0 received, 100% packet loss, time 1005ms

# ## -- snap k8s installation -- ## 
# # sudo snap install k8s \
# #   --classic \
# #   --channel=1.37-classic/stable

# # snap info k8s

# sudo snap install k8s \
#   --classic \
#   --channel=1.35-classic/stable

# sudo k8s enable local-storage
# sudo k8s enable ingress
# sudo k8s enable load-balancer
# sudo k8s enable gateway
# sudo k8s status

# sudo k8s bootstrap --address 192.168.1.10

# sudo k8s status --wait-ready
# sudo k8s kubectl get nodes
# sudo k8s kubectl get pods -A

# ## -- vpn setup -- ##
# ps -p 1 -o comm=
# free -h
# ip -br addr

# # chmod +x setup-tailscale.sh
# # sudo ./setup-tailscale.sh k8s-control
# # sudo ./setup-tailscale.sh k8s-worker1

# # chmod +x setup-wireguard.sh
# # sudo ./setup-wireguard.sh k8s-control
# # sudo ./setup-wireguard.sh k8s-worker1

# # chmod +x setup-openvpn.sh
# # sudo ./setup-openvpn.sh k8s-control
# # sudo ./setup-openvpn.sh k8s-worker1

# sudo snap install k8s \
#   --classic \
#   --channel=1.37-classic/stable

# sudo k8s status
# sudo k8s kubectl get pods -A
# sudo k8s kubectl get services -A