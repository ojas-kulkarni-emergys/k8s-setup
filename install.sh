#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Canonical Kubernetes setup wizard and node lifecycle manager.
#
# Interactive:
#   sudo ./install.sh [path/to/config.yml]
#
# Direct commands:
#   sudo ./install.sh --start-cluster [path/to/config.yml]
#   sudo ./install.sh --stop-cluster [path/to/config.yml]
#   sudo ./install.sh --cluster-status [path/to/config.yml]
#   sudo ./install.sh --uninstall [path/to/config.yml]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$SCRIPT_DIR/config.yml"
ACTION=""

# Accept an action and an optional config path in either order.
for arg in "$@"; do
    case "$arg" in
        --start-cluster|--stop-cluster|--cluster-status|--uninstall)
            ACTION="$arg"
            ;;
        *)
            CONFIG="$arg"
            ;;
    esac
done

[[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 [config.yml|--start-cluster|--stop-cluster|--cluster-status|--uninstall]" >&2
    exit 1
fi

# ------------------------------------------------------------
# Configuration helpers
# ------------------------------------------------------------

ensure_yaml() {
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        echo "Installing Python YAML support..."
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-yaml
    fi
}

require_config() {
    [[ -f "$CONFIG" ]] || {
        echo "ERROR: Config not found: $CONFIG" >&2
        return 2
    }
    ensure_yaml
}

cfg() {
    python3 - "$CONFIG" "$1" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}

for part in sys.argv[2].split("."):
    d = d.get(part) if isinstance(d, dict) else None

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

# ------------------------------------------------------------
# Canonical Kubernetes cluster controls
# ------------------------------------------------------------

cluster_control() {
    local action="${1:-}"

    command -v snap >/dev/null 2>&1 || {
        echo "ERROR: snap is not installed." >&2
        return 1
    }

    snap list k8s >/dev/null 2>&1 || {
        echo "ERROR: Canonical Kubernetes snap 'k8s' is not installed." >&2
        return 1
    }

    case "$action" in
        --start-cluster)
            echo "Starting Canonical Kubernetes services..."
            snap start k8s
            snap services k8s
            ;;
        --stop-cluster)
            echo "Stopping Canonical Kubernetes services..."
            echo "This stops the snap services; it does not intentionally delete cluster resources."
            snap stop k8s
            snap services k8s
            ;;
        --cluster-status)
            echo "Canonical Kubernetes snap service status:"
            snap services k8s
            ;;
        *)
            echo "Unknown cluster action: $action" >&2
            return 2
            ;;
    esac
}

# ------------------------------------------------------------
# Destructive uninstall for the current node
# ------------------------------------------------------------

uninstall_node() {
    require_config

    local role node_name vpn client_name
    role="$(cfg role)"
    node_name="$(cfg node_name)"
    vpn="$(cfg vpn)"
    client_name="$(cfg openvpn.client_name)"

    [[ -n "$client_name" ]] || client_name="${node_name#k8s-}"

    if [[ "$role" != "control" && "$role" != "worker" ]]; then
        echo "ERROR: config.yml role must be 'control' or 'worker'." >&2
        return 2
    fi

    if [[ -z "$node_name" ]]; then
        echo "ERROR: config.yml node_name is required." >&2
        return 2
    fi

    case "$vpn" in
        none|tailscale|wireguard|openvpn) ;;
        *)
            echo "ERROR: config.yml vpn must be none, tailscale, wireguard, or openvpn." >&2
            return 2
            ;;
    esac

    echo
    echo "================================================"
    echo " WARNING: DESTRUCTIVE NODE UNINSTALL"
    echo "================================================"
    echo "Config : $CONFIG"
    echo "Role   : $role"
    echo "Node   : $node_name"
    echo "VPN    : $vpn"
    echo

    if [[ "$role" == "control" ]]; then
        echo "This is configured as the CONTROL PLANE."
        echo "Retire or uninstall worker nodes separately."
        echo "Removing the Kubernetes snap may destroy local cluster state."
    else
        echo "This removes Kubernetes from this WORKER only."
    fi

    echo
    echo "Shared OS dependencies will be kept."
    echo "Other nodes will not be modified."
    echo "Review VPN-specific cleanup paths before proceeding."
    echo

    local typed confirm
    read -r -p "Type '$node_name' to confirm: " typed
    [[ "$typed" == "$node_name" ]] || {
        echo "Confirmation did not match. Nothing was removed."
        return 1
    }

    read -r -p "Proceed with uninstall? Type YES: " confirm
    [[ "$confirm" == "YES" ]] || {
        echo "Cancelled."
        return 0
    }

    echo
    echo "== Removing Canonical Kubernetes =="

    if command -v snap >/dev/null 2>&1 && snap list k8s >/dev/null 2>&1; then
        snap stop k8s || true
        snap remove --purge k8s
    else
        echo "Canonical Kubernetes snap not found; skipping."
    fi

    echo
    echo "== Removing configured VPN: $vpn =="

    case "$vpn" in
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
            if [[ "$role" == "control" ]]; then
                systemctl disable --now openvpn-server@server 2>/dev/null || true

                # These are common paths; confirm they match your setup scripts.
                rm -rf /etc/openvpn/server /etc/openvpn/easy-rsa /root/openvpn-clients

                if command -v apt-get >/dev/null 2>&1; then
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y openvpn easy-rsa || true
                fi

                echo "Review firewall rules and remove any lab-specific OpenVPN rules manually."
            else
                if [[ "$client_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
                    systemctl disable --now "openvpn-client@${client_name}" 2>/dev/null || true
                    rm -f "/etc/openvpn/client/${client_name}.conf"
                    rm -rf "/etc/openvpn/client/${client_name}"
                else
                    echo "WARNING: unsafe client name; skipped client-file cleanup."
                fi

                if command -v apt-get >/dev/null 2>&1; then
                    DEBIAN_FRONTEND=noninteractive apt-get purge -y openvpn || true
                fi
            fi
            ;;
    esac

    echo
    echo "Uninstall actions completed for $node_name ($role)."

    if [[ "$role" == "control" ]]; then
        echo "Remember: workers are separate machines and must be handled separately."
    fi

    echo "Check remaining services, network interfaces, firewall rules, and files manually."
}

# ------------------------------------------------------------
# Interactive install/configuration wizard
# ------------------------------------------------------------

install_wizard() {
    require_config

    local current_role current_name current_vpn current_channel
    local current_addr current_token current_addons current_endpoint
    local current_client current_bundle current_wg

    current_role="$(cfg role)"
    current_name="$(cfg node_name)"
    current_vpn="$(cfg vpn)"
    current_channel="$(cfg kubernetes.channel)"
    current_addr="$(cfg kubernetes.node_address)"
    current_token="$(cfg kubernetes.join_token)"

    current_addons="$(python3 - "$CONFIG" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}

print(",".join(d.get("kubernetes", {}).get("addons", []) or []))
PY
)"

    current_endpoint="$(cfg openvpn.endpoint)"
    current_client="$(cfg openvpn.client_name)"
    current_bundle="$(cfg paths.openvpn_client_bundle)"
    current_wg="$(cfg paths.wireguard_config)"

    printf '\n=== Canonical Kubernetes setup wizard ===\n'
    printf "Choose this machine's role:\n  1) Control plane\n  2) Worker\n"

    local choice role
    read -r -p "Role [1/2, current: ${current_role:-control}]: " choice

    case "${choice:-}" in
        1) role=control ;;
        2) role=worker ;;
        *) role="${current_role:-control}" ;;
    esac

    local suggested_name name_default node_name
    suggested_name="k8s-control"
    [[ "$role" == "worker" ]] && suggested_name="k8s-worker1"

    name_default="$suggested_name"
    if [[ "$current_role" == "$role" && -n "$current_name" ]]; then
        name_default="$current_name"
    fi

    read -r -p "Node name [$name_default]: " node_name
    node_name="${node_name:-$name_default}"

    printf '\nVPN method:\n'
    printf '  1) Tailscale (automatic VPN IP)\n'
    printf '  2) WireGuard (requires configured wg0.conf)\n'
    printf '  3) OpenVPN (control creates client bundles; workers need their bundle)\n'
    printf '  4) No VPN (use a reachable node IP)\n'

    local default_vpn vpn
    case "$current_vpn" in
        tailscale) default_vpn=1 ;;
        wireguard) default_vpn=2 ;;
        openvpn) default_vpn=3 ;;
        *) default_vpn=4 ;;
    esac

    read -r -p "VPN [1-4, current: $default_vpn]: " choice

    case "${choice:-$default_vpn}" in
        1) vpn=tailscale ;;
        2) vpn=wireguard ;;
        3) vpn=openvpn ;;
        4) vpn=none ;;
        *) echo "Invalid VPN choice." >&2; return 2 ;;
    esac

    local channel node_address join_token
    read -r -p "Canonical Kubernetes snap channel [${current_channel:-1.35-classic/stable}]: " channel
    channel="${channel:-${current_channel:-1.35-classic/stable}}"

    node_address="auto"
    if [[ "$vpn" == "none" ]]; then
        read -r -p "Reachable IP for this node [${current_addr:-}]: " node_address
        node_address="${node_address:-$current_addr}"

        [[ -n "$node_address" && "$node_address" != "auto" ]] || {
            echo "A node IP is required when VPN is disabled." >&2
            return 2
        }
    fi

    join_token="$current_token"
    if [[ "$role" == "worker" ]]; then
        echo "Generate a worker token on the control plane with:"
        echo "  sudo k8s get-join-token $node_name --worker"

        local entered_token
        read -r -p "Worker join token (input hidden; Enter keeps current): " -s entered_token
        echo

        join_token="${entered_token:-$current_token}"
        [[ -n "$join_token" ]] || {
            echo "Worker join token is required." >&2
            return 2
        }
    fi

    local endpoint client_name bundle wg_config
    endpoint="$current_endpoint"
    client_name="$current_client"
    bundle="$current_bundle"
    wg_config="$current_wg"

    if [[ "$vpn" == "openvpn" ]]; then
        if [[ "$role" == "control" ]]; then
            local entered_endpoint
            read -r -p "OpenVPN public IP/DNS endpoint [${endpoint:-vpn.example.com}]: " entered_endpoint
            endpoint="${entered_endpoint:-$endpoint}"
        else
            local default_client entered_client entered_bundle
            default_client="worker1"
            [[ "$node_name" == *worker2* ]] && default_client="worker2"

            if [[ "$current_role" != "worker" || "$current_name" != "$node_name" ]]; then
                client_name="$default_client"
                bundle="./${default_client}.tar.gz"
            fi

            read -r -p "OpenVPN client name [${client_name:-$default_client}]: " entered_client
            client_name="${entered_client:-${client_name:-$default_client}}"

            read -r -p "Path to this worker's client bundle [${bundle:-./${default_client}.tar.gz}]: " entered_bundle
            bundle="${entered_bundle:-${bundle:-./${default_client}.tar.gz}}"
        fi
    fi

    if [[ "$vpn" == "wireguard" ]]; then
        local entered_wg
        read -r -p "Path to configured WireGuard wg0.conf [${wg_config:-./wg0.conf}]: " entered_wg
        wg_config="${entered_wg:-$wg_config}"
    fi

    local addons entered_addons
    addons="$current_addons"

    if [[ "$role" == "control" ]]; then
        echo "Control-plane addons (comma-separated; Enter keeps current; use none for none)."
        read -r -p "Addons [${current_addons:-local-storage,ingress,load-balancer,gateway}]: " entered_addons

        if [[ -n "$entered_addons" ]]; then
            if [[ "$entered_addons" == "none" ]]; then
                addons=""
            else
                addons="$entered_addons"
            fi
        fi
    else
        addons=""
    fi

    python3 - "$CONFIG" "$role" "$node_name" "$vpn" "$channel" \
        "$node_address" "$join_token" "$addons" "$endpoint" \
        "$client_name" "$bundle" "$wg_config" <<'PY'
import sys
import yaml

(path, role, name, vpn, channel, address, token, addons,
 endpoint, client, bundle, wg_config) = sys.argv[1:]

with open(path, encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}

d["role"] = role
d["node_name"] = name
d["vpn"] = vpn

d.setdefault("kubernetes", {})["channel"] = channel
d["kubernetes"]["node_address"] = address
d["kubernetes"]["join_token"] = token
d["kubernetes"]["addons"] = [x.strip() for x in addons.split(",") if x.strip()]

d.setdefault("openvpn", {})["endpoint"] = endpoint
d["openvpn"]["client_name"] = client

d.setdefault("paths", {})["openvpn_client_bundle"] = bundle
d["paths"]["wireguard_config"] = wg_config

with open(path, "w", encoding="utf-8") as f:
    yaml.safe_dump(
        d,
        f,
        sort_keys=False,
        default_flow_style=False,
        allow_unicode=True,
    )
PY

    printf '\nReviewing selected setup:\n'
    printf '  Role: %s\n  Node: %s\n  VPN: %s\n  Channel: %s\n  Config: %s\n' \
        "$role" "$node_name" "$vpn" "$channel" "$CONFIG"

    local confirm
    read -r -p "Start VPN setup and Kubernetes installation now? [y/N]: " confirm

    [[ "$confirm" =~ ^[Yy]$ ]] || {
        echo "Saved configuration to $CONFIG. No installation started."
        return 0
    }

    exec "$SCRIPT_DIR/setup-cluster.sh" "$CONFIG"
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

main_menu() {
    while true; do
        echo
        echo "================================================"
        echo "   Canonical Kubernetes Node Management"
        echo "================================================"
        echo "Config: $CONFIG"
        echo "  1) Install / configure this node"
        echo "  2) Start Kubernetes cluster services"
        echo "  3) Stop Kubernetes cluster services"
        echo "  4) Show Kubernetes service status"
        echo "  5) Uninstall Kubernetes + configured VPN on this node"
        echo "  6) Exit"

        local menu_choice
        read -r -p "Select [1-6]: " menu_choice

        case "${menu_choice:-}" in
            1) install_wizard || true ;;
            2) cluster_control --start-cluster || true ;;
            3) cluster_control --stop-cluster || true ;;
            4) cluster_control --cluster-status || true ;;
            5) uninstall_node || true ;;
            6) return 0 ;;
            *) echo "Invalid choice. Select 1-6." ;;
        esac
    done
}

# ------------------------------------------------------------
# Entry point
# ------------------------------------------------------------

case "$ACTION" in
    --start-cluster|--stop-cluster|--cluster-status)
        cluster_control "$ACTION"
        ;;
    --uninstall)
        uninstall_node
        ;;
    "")
        main_menu
        ;;
    *)
        echo "Unsupported action: $ACTION" >&2
        exit 2
        ;;
esac
