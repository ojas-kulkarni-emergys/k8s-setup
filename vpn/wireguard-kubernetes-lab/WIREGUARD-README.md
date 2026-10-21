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

WireGuard setup
---------------
1. Install WireGuard on all three Ubuntu nodes:
     sudo apt update && sudo apt install -y wireguard

2. On EACH node, generate its own keys:
     umask 077
     wg genkey | tee privatekey | wg pubkey > publickey
   Keep privatekey secret. Use the corresponding publickey in the other nodes'
   Peer sections. Store keys securely; do not paste them into chats.

3. Edit the matching config template:
   - wg0-control.conf on the control node
   - wg0-worker1.conf on worker1
   - wg0-worker2.conf on worker2
   Replace <CONTROL_PRIVATE_KEY> and each <..._PUBLIC_KEY> with the right
   key contents (no angle brackets).
   Replace <CONTROL_PUBLIC_IP_OR_DNS> with the control node's public endpoint.
   Worker templates use PersistentKeepalive=25 for NAT traversal.

4. Install each completed config:
     sudo install -m 600 wg0.conf /etc/wireguard/wg0.conf
     sudo systemctl enable --now wg-quick@wg0
     sudo wg show
     ip -br addr show wg0

5. Test VPN connectivity:
   From control: ping 10.20.0.2 and ping 10.20.0.3
   From worker1: ping 10.20.0.1
   From worker2: ping 10.20.0.1

Firewall
--------
Allow UDP 51820 inbound to the control node. On Ubuntu UFW, if enabled:
  sudo ufw allow 51820/udp
Also configure cloud security groups/router port forwarding as applicable.
Do not expose Kubernetes API, etcd, or pod-network ports publicly.

Kubernetes note
---------------
A working VPN does not automatically configure Canonical Kubernetes to use
VPN addresses or join nodes. Before bootstrapping/joining, verify the installed
Canonical Kubernetes CLI's supported network/address options and ensure the
cluster CNI routes pod traffic correctly over the VPN. Do not run the
WireGuard templates unchanged: keys and the control public endpoint are
placeholders.
