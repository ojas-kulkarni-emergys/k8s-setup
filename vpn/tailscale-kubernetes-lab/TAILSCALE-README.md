Remote Canonical Kubernetes VPN configuration templates
=========================================================

Topology:
  k8s-control  WireGuard VPN IP 10.20.0.1
  k8s-worker1  WireGuard VPN IP 10.20.0.2
  k8s-worker2  WireGuard VPN IP 10.20.0.3
  WireGuard port: UDP 51820

IMPORTANT
---------
These are templates, not ready-to-run configs. Replace every <PLACEHOLDER>.
Generate a DIFFERENT private/public key pair on each node. Never share private
keys or commit them to source control. The control node needs a reachable
public IP/DNS and UDP 51820 allowed through its firewall/NAT. If the control
node is behind a router, forward UDP 51820 to it.

Firewall
--------
Allow UDP 51820 inbound to the control node. On Ubuntu UFW, if enabled:
  sudo ufw allow 51820/udp
Also configure cloud security groups/router port forwarding as applicable.
Do not expose Kubernetes API, etcd, or pod-network ports publicly.

Tailscale
---------
Tailscale does not normally require manually authored peer configuration files.
Install and authenticate each node instead:
  sudo ./setup-tailscale.sh k8s-control
  sudo ./setup-tailscale.sh k8s-worker1
  sudo ./setup-tailscale.sh k8s-worker2
Authenticate each device using the URL shown, then verify:
  tailscale status
  tailscale ip -4
  ping <other-node-Tailscale-IP>

The optional tailscale-node-notes.txt in this bundle records the intended node
names and addresses. Tailscale assigns the actual 100.x.y.z addresses; do not
assume the example addresses in this file are real.
