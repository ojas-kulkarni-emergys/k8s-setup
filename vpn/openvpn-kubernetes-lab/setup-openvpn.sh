#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Lab OpenVPN server setup for a 3-node Canonical Kubernetes cluster.
# Run ONLY on the intended control-plane/OpenVPN-server machine:
#   sudo bash setup-openvpn.sh <PUBLIC_IP_OR_DNS>
#
# Creates:
#   /etc/openvpn/server/server.conf
#   /root/openvpn-clients/worker1.tar.gz
#   /root/openvpn-clients/worker2.tar.gz
#
# The worker archives contain client private keys. Transfer them securely and
# delete temporary copies after installation. Do not email/post them publicly.

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0 <PUBLIC_IP_OR_DNS>" >&2
  exit 1
fi
if [[ $# -ne 1 || -z "${1:-}" ]]; then
  echo "Usage: sudo bash $0 <PUBLIC_IP_OR_DNS>" >&2
  echo "Example: sudo bash $0 vpn.example.com" >&2
  exit 2
fi

VPN_ENDPOINT="$1"
if [[ "$VPN_ENDPOINT" =~ [[:space:]] || "$VPN_ENDPOINT" == *"/"* ]]; then
  echo "Use only a public IPv4 address or DNS hostname, without scheme/path." >&2
  exit 2
fi

if [[ ! -r /etc/os-release ]]; then
  echo "Cannot identify Linux distribution." >&2
  exit 1
fi
. /etc/os-release
if [[ "${ID:-}" != "ubuntu" ]]; then
  echo "This script is intended for Ubuntu. Detected: ${ID:-unknown}" >&2
  exit 1
fi

if [[ -e /etc/openvpn/server/server.conf || -e /etc/openvpn/easy-rsa/pki/ca.crt ]]; then
  echo "Existing OpenVPN configuration/PKI found. Refusing to overwrite it." >&2
  echo "Back up and review existing files before adapting this script." >&2
  exit 1
fi

echo "Installing OpenVPN and Easy-RSA..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y openvpn easy-rsa

EASYRSA_DIR="/etc/openvpn/easy-rsa"
SERVER_DIR="/etc/openvpn/server"
CLIENT_OUT="/root/openvpn-clients"
install -d -m 755 /var/lib/openvpn
install -d -m 700 "$EASYRSA_DIR" "$SERVER_DIR" "$CLIENT_OUT"

# Keep the CA and its private key on the server. For production, prefer an
# offline CA and sign client/server requests on that separate machine.
cp -a /usr/share/easy-rsa/. "$EASYRSA_DIR/"
cd "$EASYRSA_DIR"

export EASYRSA_BATCH=1
export EASYRSA_REQ_CN="Kubernetes-Lab-OpenVPN-CA"
./easyrsa init-pki
# Encrypted CA private key: Easy-RSA prompts for a passphrase.
unset EASYRSA_BATCH
./easyrsa build-ca

export EASYRSA_BATCH=1
./easyrsa gen-req server nopass
./easyrsa sign-req server server
./easyrsa gen-req worker1 nopass
./easyrsa sign-req client worker1
./easyrsa gen-req worker2 nopass
./easyrsa sign-req client worker2
./easyrsa gen-crl

# Server TLS material.
sudo install -m 644 pki/ca.crt "$SERVER_DIR/ca.crt"
sudo install -m 644 pki/issued/server.crt "$SERVER_DIR/server.crt"
sudo install -m 600 pki/private/server.key "$SERVER_DIR/server.key"
sudo install -m 644 pki/crl.pem "$SERVER_DIR/crl.pem"
sudo openvpn --genkey secret "$SERVER_DIR/ta.key"
sudo chmod 600 "$SERVER_DIR/ta.key"

cat > "$SERVER_DIR/server.conf" <<EOF
# OpenVPN server for a small Kubernetes lab.
port 1194
proto udp
dev tun
topology subnet
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist /var/lib/openvpn/ipp.txt
client-config-dir /etc/openvpn/server/ccd

ca /etc/openvpn/server/ca.crt
cert /etc/openvpn/server/server.crt
key /etc/openvpn/server/server.key
dh none
ecdh-curve prime256v1
crl-verify /etc/openvpn/server/crl.pem
tls-crypt /etc/openvpn/server/ta.key
remote-cert-tls client
tls-version-min 1.2
verify-client-cert require
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305

# Permit connected VPN clients (the workers) to reach each other.
client-to-client
keepalive 10 60
persist-key
persist-tun
user nobody
group nogroup
verb 3
EOF
sudo chmod 600 "$SERVER_DIR/server.conf"

# Give each worker a stable VPN address for easier Kubernetes node configuration.
sudo install -d -m 700 "$SERVER_DIR/ccd"
printf '%s\n' 'ifconfig-push 10.8.0.2 255.255.255.0' > "$SERVER_DIR/ccd/worker1"
printf '%s\n' 'ifconfig-push 10.8.0.3 255.255.255.0' > "$SERVER_DIR/ccd/worker2"
sudo chmod 600 "$SERVER_DIR/ccd/worker1" "$SERVER_DIR/ccd/worker2"

# Client configs refer to their own files under /etc/openvpn/client/<name>/.
for CLIENT in worker1 worker2; do
  STAGE="$CLIENT_OUT/$CLIENT"
  sudo install -d -m 700 "$STAGE/$CLIENT"
  sudo install -m 644 "$EASYRSA_DIR/pki/ca.crt" "$STAGE/$CLIENT/ca.crt"
  sudo install -m 644 "$EASYRSA_DIR/pki/issued/$CLIENT.crt" "$STAGE/$CLIENT/$CLIENT.crt"
  sudo install -m 600 "$EASYRSA_DIR/pki/private/$CLIENT.key" "$STAGE/$CLIENT/$CLIENT.key"
  sudo install -m 600 "$SERVER_DIR/ta.key" "$STAGE/$CLIENT/ta.key"

  cat > "$STAGE/$CLIENT.conf" <<EOF
client
dev tun
proto udp
remote ${VPN_ENDPOINT} 1194
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
verify-x509-name server name
tls-version-min 1.2
tls-crypt /etc/openvpn/client/${CLIENT}/ta.key
ca /etc/openvpn/client/${CLIENT}/ca.crt
cert /etc/openvpn/client/${CLIENT}/${CLIENT}.crt
key /etc/openvpn/client/${CLIENT}/${CLIENT}.key
auth-nocache
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
verb 3
EOF
  sudo chmod 600 "$STAGE/$CLIENT.conf"
  tar -czf "$CLIENT_OUT/${CLIENT}.tar.gz" -C "$STAGE" .
  sudo chmod 600 "$CLIENT_OUT/${CLIENT}.tar.gz"
done

# Permit VPN ingress if UFW is installed and active. Cloud firewalls/router
# port forwarding must also allow UDP/1194 to this machine.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  sudo ufw allow 1194/udp comment 'OpenVPN Kubernetes lab'
fi

sudo systemctl enable --now openvpn-server@server

echo
echo "OpenVPN server setup finished."
echo "Endpoint configured for clients: ${VPN_ENDPOINT}:1194/udp"
echo "VPN subnet: 10.8.0.0/24 (server 10.8.0.1, worker1 10.8.0.2, worker2 10.8.0.3)"
echo "Client bundles:"
echo "  $CLIENT_OUT/worker1.tar.gz"
echo "  $CLIENT_OUT/worker2.tar.gz"
echo
echo "Check server:"
echo "  sudo systemctl status openvpn-server@server --no-pager"
echo "  sudo journalctl -u openvpn-server@server -n 80 --no-pager"
echo
echo "Before connecting clients, ensure:"
echo "  - UDP 1194 is allowed in the host/cloud firewall."
echo "  - If behind a router/NAT, forward UDP 1194 to this server."
echo "  - The endpoint supplied to this script is reachable from workers."
echo "  - If this is WSL2, Windows/host/router forwarding and inbound WSL access"
echo "    must be explicitly configured; a WSL address alone is not public."
echo
echo "The CA private key is under $EASYRSA_DIR/pki/private/ca.key."
echo "Keep it protected; do not copy it to workers."
