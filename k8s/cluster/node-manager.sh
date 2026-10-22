#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Configuration and lifecycle submenu module.
#
# Interactive:
#   sudo bash k8s/cluster/node-manager.sh [path/to/config.yaml]
#
# Direct commands:
#   sudo bash k8s/cluster/node-manager.sh --start-cluster [path/to/config.yaml]
#   sudo bash k8s/cluster/node-manager.sh --stop-cluster [path/to/config.yaml]
#   sudo bash k8s/cluster/node-manager.sh --cluster-status [path/to/config.yaml]
#   sudo bash k8s/cluster/node-manager.sh --uninstall [path/to/config.yaml]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIG="$SCRIPT_DIR/config.yaml"
ACTION=""

# Accept an action and an optional config path in either order.
for arg in "$@"; do
    case "$arg" in
        --start-cluster|--stop-cluster|--cluster-status|--uninstall|--worker-token|--configure|--controls|--install-cluster|--install-control|--install-worker|--models)
            ACTION="$arg"
            ;;
        --*) echo "Unknown option: $arg" >&2; exit 2 ;;
        *)
            CONFIG="$arg"
            ;;
    esac
done

[[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo $0 [config.yaml|--start-cluster|--stop-cluster|--cluster-status|--uninstall]" >&2
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
    local scope="${1:-all}"
    require_config

    local role node_name vpn client_name
    role="$(cfg role)"
    node_name="$(cfg node_name)"
    vpn="$(cfg vpn)"
    client_name="$(cfg openvpn.client_name)"

    [[ -n "$client_name" ]] || client_name="${node_name#k8s-}"

    if [[ "$role" != "control" && "$role" != "worker" ]]; then
        echo "ERROR: config.yaml role must be 'control' or 'worker'." >&2
        return 2
    fi

    if [[ -z "$node_name" ]]; then
        echo "ERROR: config.yaml node_name is required." >&2
        return 2
    fi

    case "$vpn" in
        none|tailscale|wireguard|openvpn) ;;
        *)
            echo "ERROR: config.yaml vpn must be none, tailscale, wireguard, or openvpn." >&2
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
    echo "Remove : $scope"
    echo

    if [[ "$role" == "control" && "$scope" != vpn ]]; then
        echo "This is configured as the CONTROL PLANE."
        echo "Retire or uninstall worker nodes separately."
        echo "Removing the Kubernetes snap may destroy local cluster state."
    else
        echo "Only the selected components on this node will be removed."
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

    if [[ "$scope" != vpn ]] && command -v snap >/dev/null 2>&1 && snap list k8s >/dev/null 2>&1; then
        snap stop k8s || true
        snap remove --purge k8s
    else
        echo "Canonical Kubernetes snap not found; skipping."
    fi

    if [[ "$scope" != cluster ]]; then
        bash "$SCRIPT_DIR/k8s/cluster/vpn_manager.sh" uninstall "$CONFIG"
    fi

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
        "") role="${current_role:-control}" ;;
        *) echo "Invalid role." >&2; return 2 ;;
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
    [[ "$node_name" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || { echo "Invalid node name." >&2; return 2; }

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

    echo "Configuration saved to $CONFIG. Install VPN and cluster separately from the main menu."
}

# ------------------------------------------------------------
# Main menu
# ------------------------------------------------------------

worker_token() {
    local name
    read -r -p 'Worker node name: ' name || return 1
    [[ "$name" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || { echo 'Invalid node name.' >&2; return 2; }
    k8s get-join-token "$name" --worker
}
configure_menu() {
    local choice
    while true; do
        set +e
        printf '\n1) Configure node\n2) Generate worker join token (on control plane)\n0) Back\n'
        read -r -p 'Select: ' choice || return 0
        case "$choice" in
            1) ( set -e; install_wizard ) ;; 2) worker_token ;; 0) return ;; *) echo 'Invalid choice.' ;;
        esac
    done
}
cluster_menu() {
    local choice
    while true; do
        set +e
        printf '\n1) Start cluster\n2) Stop cluster\n3) Show cluster\n4) Cluster / VPN logs\n0) Back\n'
        read -r -p 'Select: ' choice || return 0
        case "$choice" in
            1) cluster_control --start-cluster ;;
            2) cluster_control --stop-cluster ;;
            3) cluster_control --cluster-status ;;
            4) journalctl -u 'snap.k8s.*' -u tailscaled -u 'wg-quick@*' -u 'openvpn-*' -n 100 --no-pager ;;
            0) return ;; *) echo 'Invalid choice.' ;;
        esac
    done
}
uninstall_menu() {
    local choice
    printf '\n1) Uninstall cluster only\n2) Uninstall configured VPN only\n3) Uninstall both\n0) Back\n'
    read -r -p 'Select: ' choice || return 0
    case "$choice" in
        1) ( set -e; uninstall_node cluster ) ;; 2) ( set -e; uninstall_node vpn ) ;; 3) ( set -e; uninstall_node all ) ;; 0) return ;; *) echo 'Invalid choice.' ;;
    esac
}
install_cluster() {
    require_config
    case "$(cfg role)" in
        control) bash "$SCRIPT_DIR/k8s/cluster/setup-control-plane.sh" "$CONFIG" ;;
        worker) bash "$SCRIPT_DIR/k8s/cluster/setup-worker.sh" "$CONFIG" ;;
        *) echo 'Set role: control or role: worker in config.yaml.' >&2; return 2 ;;
    esac
}
node_menu() {
    local choice
    while true; do
        printf '\n=== Node manager ===\n1) Configure node\n2) Generate worker token\n3) Install configured node role\n4) Install control plane\n5) Install worker\n6) Cluster controls / logs\n7) Models / router\n8) Uninstall\n0) Back\n'
        read -r -p 'Select: ' choice || return 0
        case "$choice" in
            1) action=--configure ;; 2) action=--worker-token ;;
            3) action=--install-cluster ;; 4) action=--install-control ;;
            5) action=--install-worker ;; 6) action=--controls ;;
            7) action=--models ;; 8) action=--uninstall ;;
            0) return 0 ;; *) continue ;;
        esac
        bash "${BASH_SOURCE[0]}" "$action" "$CONFIG" || echo 'Node action failed.' >&2
    done
}
case "$ACTION" in
  "") node_menu ;;
  --configure) configure_menu ;;
  --controls) cluster_menu ;;
  --worker-token) worker_token ;;
  --install-cluster) install_cluster ;;
  --install-control) bash "$SCRIPT_DIR/k8s/cluster/setup-control-plane.sh" "$CONFIG" ;;
  --install-worker) bash "$SCRIPT_DIR/k8s/cluster/setup-worker.sh" "$CONFIG" ;;
  --models) bash "$SCRIPT_DIR/k8s/node/llm-d.setup.sh" "$CONFIG" ;;
  --uninstall) uninstall_menu ;;
  --start-cluster|--stop-cluster|--cluster-status) cluster_control "$ACTION" ;;
  *) echo 'Unknown node-manager action.' >&2; exit 2 ;;
esac
