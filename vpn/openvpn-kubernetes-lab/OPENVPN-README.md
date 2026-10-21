# OpenVPN setup for a 3-node Canonical Kubernetes lab

## Topology
- Control-plane machine runs OpenVPN server.
- Worker 1 and Worker 2 run OpenVPN clients.
- Example VPN subnet: 10.8.0.0/24.
- Server usually gets 10.8.0.1; workers receive client addresses from the pool.

## 1. On the control-plane/OpenVPN-server machine
Copy `setup-openvpn.sh` to the machine, then run:

    chmod +x setup-openvpn.sh
    sudo ./setup-openvpn.sh <PUBLIC_IP_OR_DNS>

Example:

    sudo ./setup-openvpn.sh vpn.example.com

The script installs `openvpn` and `easy-rsa`, creates a CA and unique server/client certificates, writes `/etc/openvpn/server/server.conf`, creates client bundles under `/root/openvpn-clients/`, and starts the server. It prompts for a CA passphrase.

## 2. Make the server reachable
- Permit inbound UDP 1194 in the server's host firewall and cloud security group.
- If the server is behind a router, forward UDP 1194 to the server.
- If the server is WSL2, extra Windows and router inbound forwarding is needed; WSL is not automatically an internet-reachable VPN server.
- Do not expose Kubernetes API, etcd, or other cluster ports publicly.

## 3. Securely transfer each bundle to its corresponding worker
From the control plane, use SSH/SCP (replace the account and hostnames):

    sudo install -o "$SUDO_USER" -g "$SUDO_USER" -m 600 /root/openvpn-clients/worker1.tar.gz "$HOME/worker1.tar.gz"
    sudo install -o "$SUDO_USER" -g "$SUDO_USER" -m 600 /root/openvpn-clients/worker2.tar.gz "$HOME/worker2.tar.gz"
    scp "$HOME/worker1.tar.gz" <user>@<WORKER1_HOST>:/tmp/
    scp "$HOME/worker2.tar.gz" <user>@<WORKER2_HOST>:/tmp/

Run the install commands from the same shell where sudo is available and verify the destination home directory first. If you are root already, set the destination path and owner explicitly. Never send client private keys in public channels; delete temporary copies after installation.

## 4. On Worker 1
Copy `worker1.tar.gz` to the worker's `/tmp`, then:

    sudo apt update
    sudo apt install -y openvpn
    sudo install -d -m 700 /etc/openvpn/client
    sudo tar -xzf /tmp/worker1.tar.gz -C /etc/openvpn/client
    sudo chmod 600 /etc/openvpn/client/worker1.conf
    sudo chmod 600 /etc/openvpn/client/worker1/worker1.key /etc/openvpn/client/worker1/ta.key
    sudo systemctl enable --now openvpn-client@worker1
    sudo systemctl status openvpn-client@worker1 --no-pager
    ip -br addr show tun0
    sudo journalctl -u openvpn-client@worker1 -n 80 --no-pager

## 5. On Worker 2
Use the same commands, replacing `worker1` with `worker2` and the archive filename accordingly.

## 6. Check server and VPN reachability
On the control plane:

    sudo systemctl status openvpn-server@server --no-pager
    sudo journalctl -u openvpn-server@server -n 80 --no-pager
    ip -br addr show tun0

On each worker, inspect `tun0` and confirm the VPN client service is active. Test VPN reachability to the server's VPN IP (usually 10.8.0.1). Check worker-to-worker reachability as well; host firewall rules may need to allow ICMP or required cluster traffic over tun0.

## 7. Kubernetes caveats
This only creates the VPN. It does not bootstrap/join Canonical Kubernetes or automatically force Kubernetes to use the VPN address. Before joining workers, check `sudo k8s join-cluster --help` and the installed Canonical Kubernetes docs for the supported node-address setting. Verify that the pod network/CNI can operate with your chosen VPN routing and MTU. Never expose Kubernetes API (6443), etcd (2379/2380), or pod-network ports to the public internet.

## Security notes
- The CA private key stays on the server in this lab script. For production, keep the CA offline and sign requests on a dedicated system.
- Each worker has a unique certificate and private key.
- Keep `/root/openvpn-clients/*.tar.gz` private; delete after secure transfer.
- Back up the CA and PKI securely. To revoke a client, use Easy-RSA to revoke its certificate, regenerate the CRL, update `/etc/openvpn/server/crl.pem`, then restart the server.
