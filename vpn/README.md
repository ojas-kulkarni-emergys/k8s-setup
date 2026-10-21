Remote Canonical Kubernetes VPN configuration templates
=========================================================

Purpose
-------
This bundle contains example setup files for connecting a remote 3-node
Canonical Kubernetes lab over a VPN:

  k8s-control  - control-plane node and (for OpenVPN) VPN server
  k8s-worker1  - worker node
  k8s-worker2  - worker node

Choose ONE VPN method for the lab. Do not run all three methods on the same
nodes unless you intentionally know how to route between multiple VPNs.

Files
-----
vpn/openvpn-kubernetes-lab
    setup-tailscale.sh                 Installs/authenticates Tailscale on a node

vpn/tailscale-kubernetes-lab
    setup-wireguard.sh                 Installs WireGuard packages on a node
    wg0-control.conf.template           WireGuard config template for control
    wg0-worker1.conf.template          WireGuard config template for worker 1
    wg0-worker2.conf.template          WireGuard config template for worker 2

vpn/wireguard-kubernetes-lab
    setup-openvpn.sh                   Creates OpenVPN server and worker bundles
    openvpn-server.conf.template        Example OpenVPN server configuration
    openvpn-worker-client.conf.template Example OpenVPN client configuration

1. Tailscale (simplest option)
------------------------------
Run on EACH Ubuntu node. Copy setup-tailscale.sh to each node first.

  chmod +x setup-tailscale.sh
  sudo ./setup-tailscale.sh k8s-control

On worker 1:
  chmod +x setup-tailscale.sh
  sudo ./setup-tailscale.sh k8s-worker1

On worker 2:
  chmod +x setup-tailscale.sh
  sudo ./setup-tailscale.sh k8s-worker2

Follow the authentication URL shown by the script for each node. Then, on
each node, check its assigned VPN address and connected peers:

  tailscale status
  tailscale ip -4
  ping <OTHER_NODE_TAILSCALE_IP>

Tailscale assigns the VPN IP automatically (typically in 100.64.0.0/10).
Use the actual IP shown on each machine; do not copy example IPs from docs.
Keep each node signed in to the same authorized tailnet.

2. WireGuard (manual peer configuration)
----------------------------------------
Run the package setup script on EACH node:

  chmod +x setup-wireguard.sh
  sudo ./setup-wireguard.sh k8s-control

On worker 1:
  sudo ./setup-wireguard.sh k8s-worker1

On worker 2:
  sudo ./setup-wireguard.sh k8s-worker2

Generate a different key pair on each node. Keep private keys secret. Edit the
matching wg0-*.conf.template and replace every placeholder with the correct
key or endpoint. The example VPN addresses are:

  k8s-control  10.20.0.1/24
  k8s-worker1  10.20.0.2/24
  k8s-worker2  10.20.0.3/24

The control node must be reachable at its public IP/DNS and UDP port 51820.
Allow UDP 51820 in the host/cloud firewall and forward it through the router if
needed. Install the completed config as /etc/wireguard/wg0.conf on each node:

  sudo install -m 600 wg0.conf /etc/wireguard/wg0.conf
  sudo systemctl enable --now wg-quick@wg0
  sudo wg show
  ip -br addr show wg0

Test the VPN IPs with ping. These templates are not ready to use until all
keys and the control endpoint are correctly filled in.

3. OpenVPN (control runs server; workers run clients)
----------------------------------------------------
IMPORTANT: unlike the other scripts, setup-openvpn.sh is run ONLY on the
control-plane/VPN-server machine. It expects a reachable public IPv4 address
or DNS name, not a Kubernetes node name. Do NOT run it on each worker.

Copy setup-openvpn.sh to the control node, then run (replace the example with
the server's reachable public IP or DNS name):

  chmod +x setup-openvpn.sh
  sudo ./setup-openvpn.sh <PUBLIC_IP_OR_DNS>

Example:
  sudo ./setup-openvpn.sh vpn.example.com

The script installs OpenVPN and Easy-RSA, creates certificates, and writes
these client bundles on the control node:

  /root/openvpn-clients/worker1.tar.gz
  /root/openvpn-clients/worker2.tar.gz

It prompts you to set a passphrase for the certificate authority. Allow inbound
UDP 1194 in the host/cloud firewall. If the server is behind a router, forward
UDP 1194 to it. A WSL2 instance is not automatically reachable from the public
internet; Windows/router forwarding may be needed, so a regular Ubuntu host or
VM with a reachable endpoint is often easier for the VPN server.

Securely transfer worker1.tar.gz to worker 1 and worker2.tar.gz to worker 2
using SSH/SCP or another secure method. These archives contain private keys;
never send them in public chat/email or commit them to source control.

On worker 1, after copying worker1.tar.gz to /tmp/worker1.tar.gz:

  sudo apt update
  sudo apt install -y openvpn
  sudo install -d -m 700 /etc/openvpn/client
  sudo tar -xzf /tmp/worker1.tar.gz -C /etc/openvpn/client
  sudo chmod 600 /etc/openvpn/client/worker1.conf
  sudo chmod 600 /etc/openvpn/client/worker1/worker1.key /etc/openvpn/client/worker1/ta.key
  sudo systemctl enable --now openvpn-client@worker1
  sudo systemctl status openvpn-client@worker1 --no-pager
  ip -br addr show tun0

On worker 2, use the same commands with `worker2` and `/tmp/worker2.tar.gz`:

  sudo apt update
  sudo apt install -y openvpn
  sudo install -d -m 700 /etc/openvpn/client
  sudo tar -xzf /tmp/worker2.tar.gz -C /etc/openvpn/client
  sudo chmod 600 /etc/openvpn/client/worker2.conf
  sudo chmod 600 /etc/openvpn/client/worker2/worker2.key /etc/openvpn/client/worker2/ta.key
  sudo systemctl enable --now openvpn-client@worker2
  sudo systemctl status openvpn-client@worker2 --no-pager
  ip -br addr show tun0

Check the OpenVPN server on the control node:

  sudo systemctl status openvpn-server@server --no-pager
  sudo journalctl -u openvpn-server@server -n 80 --no-pager
  ip -br addr show tun0

The script configures the VPN subnet as 10.8.0.0/24, with the server normally
at 10.8.0.1, worker 1 at 10.8.0.2, and worker 2 at 10.8.0.3. Verify the actual
addresses and connectivity before using them for Kubernetes node networking.

Canonical Kubernetes notes
--------------------------
A working VPN does NOT automatically configure Canonical Kubernetes to use VPN
addresses, bootstrap the control plane, or join workers. First verify VPN
connectivity between all nodes. Then check the installed CLI options and
release-specific networking guidance before bootstrapping/joining. For example:

  sudo k8s status
  sudo k8s bootstrap --help
  sudo k8s join-cluster --help

Use the supported address/network options for the installed Canonical
Kubernetes version; do not assume an option exists based on another release.
Also verify that the selected CNI/pod network routes traffic correctly over the
VPN and that the VPN MTU is suitable. VPN IPs for node-to-node traffic do not
by themselves guarantee pod-to-pod connectivity.

Security checklist
------------------
- Never expose the Kubernetes API (commonly TCP 6443), etcd (TCP 2379/2380),
  or pod-network ports directly to the public internet.
- Only open the VPN port required by the chosen method: Tailscale generally
  handles connectivity through its service; WireGuard uses UDP 51820 in these
  templates; OpenVPN uses UDP 1194 in this script.
- Keep private keys, OpenVPN client bundles, and join tokens secret.
- Use stable node names and verify actual VPN IPs before configuring Kubernetes.
- Keep the OS and VPN packages updated; use firewall rules to limit access.

Commands
---------------

chmod +x setup-tailscale.sh
sudo ./setup-tailscale.sh k8s-control
sudo ./setup-tailscale.sh k8s-worker1

chmod +x setup-wireguard.sh
sudo ./setup-wireguard.sh k8s-control
sudo ./setup-wireguard.sh k8s-worker1

chmod +x setup-openvpn.sh
sudo ./setup-openvpn.sh k8s-control
sudo ./setup-openvpn.sh k8s-worker1

Kubernetes note
---------------
A working VPN does not automatically configure Canonical Kubernetes to use
VPN addresses or join nodes. Before bootstrapping/joining, verify the installed
Canonical Kubernetes CLI's supported network/address options and ensure the
cluster CNI routes pod traffic correctly over the VPN. Do not run the
WireGuard templates unchanged: keys and the control public endpoint are
placeholders.