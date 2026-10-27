#!/usr/bin/env bash
set -Eeuo pipefail

# Integrates the existing vLLM Prometheus/Grafana manifest with the official
# llm-d dashboard JSON files and (optionally) the upstream OpenCost recipe.
# Run from anywhere: ./setup-llm-d-observability.sh [--install-cost]

REPO_ROOT="${REPO_ROOT:-/home/ojas/hf/k8s-setup/llm-d}"
NAMESPACE="${MONITORING_NAMESPACE:-llm-d-deployments}"
MANIFEST="${MANIFEST:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/observability-stack-updated.yaml}"
DASHBOARDS_DIR="$REPO_ROOT/guides/recipes/observability/grafana/dashboards"
INSTALL_COST=false
for arg in "$@"; do
  case "$arg" in
    --install-cost) INSTALL_COST=true ;;
    -h|--help)
      echo "Usage: $0 [--install-cost]"
      echo "  Applies the Prometheus/Grafana manifest and provisions official llm-d dashboards."
      echo "  --install-cost also invokes the upstream OpenCost inference-cost installer."
      exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

KUBECTL=(kubectl)
if command -v k8s >/dev/null 2>&1 && ! kubectl get namespace >/dev/null 2>&1; then
  # Canonical Kubernetes environments may require `sudo k8s kubectl`.
  KUBECTL=(sudo k8s kubectl)
fi

[[ -f "$MANIFEST" ]] || { echo "Manifest not found: $MANIFEST" >&2; exit 1; }
[[ -d "$DASHBOARDS_DIR" ]] || { echo "Official dashboard directory not found: $DASHBOARDS_DIR" >&2; exit 1; }

K="${KUBECTL[*]}"
echo "Applying existing Prometheus + Grafana configuration..."
"${KUBECTL[@]}" apply -f "$MANIFEST"

echo "Creating/updating ConfigMap with official llm-d dashboards..."
# File-provisioned dashboards do not run Grafana's interactive import mapping.
# Normalize the official import placeholder to the stable datasource UID below.
TMP_DASHBOARDS="$(mktemp -d)"
trap 'rm -rf "$TMP_DASHBOARDS"' EXIT
shopt -s nullglob
json_files=("$DASHBOARDS_DIR"/*.json)
(( ${#json_files[@]} > 0 )) || { echo "No dashboard JSON files found in $DASHBOARDS_DIR" >&2; exit 1; }
for dashboard_file in "${json_files[@]}"; do
  sed 's/\${DS_PROMETHEUS}/prometheus/g' "$dashboard_file" > "$TMP_DASHBOARDS/$(basename "$dashboard_file")"
done
"${KUBECTL[@]}" create configmap llm-d-official-dashboards \
  --from-file="$TMP_DASHBOARDS" \
  -n "$NAMESPACE" --dry-run=client -o yaml \
  | "${KUBECTL[@]}" apply -f -

# EPP metrics Service already exists; Envoy admin metrics need a separate Service.
# This exposes the metrics port only inside the cluster, not as a NodePort.
cat <<'YAML' | "${KUBECTL[@]}" apply -f -
apiVersion: v1
kind: Service
metadata:
  name: llm-router-envoy-metrics
  namespace: llm-d-gateway
  labels:
    app.kubernetes.io/name: llm-router-envoy-metrics
spec:
  type: ClusterIP
  selector:
    llm-d-router-gateway: llm-router-epp
  ports:
    - name: envoy-prometheus
      port: 19001
      targetPort: 19001
YAML

# Apply ConfigMaps first, then restart workloads so Grafana reads new provider paths
# and Prometheus reloads its expanded scrape configuration.
"${KUBECTL[@]}" rollout restart deployment/prometheus -n "$NAMESPACE"
"${KUBECTL[@]}" rollout restart deployment/grafana -n "$NAMESPACE"
"${KUBECTL[@]}" rollout status deployment/prometheus -n "$NAMESPACE" --timeout=180s
"${KUBECTL[@]}" rollout status deployment/grafana -n "$NAMESPACE" --timeout=180s

echo
 echo "Dashboards provisioned. Open Grafana at http://<NODE-IP>:30509 (or port-forward svc/grafana 3000:3000)."
echo "Prometheus targets: http://<NODE-IP>:30508/targets"
echo "NOTE: cost panels need the OpenCost recipe and correctly labeled model pods."

if [[ "$INSTALL_COST" == true ]]; then
  COST_INSTALLER="$REPO_ROOT/guides/recipes/observability/inferencecost/install-opencost.sh"
  [[ -x "$COST_INSTALLER" ]] || { echo "OpenCost installer missing or not executable: $COST_INSTALLER" >&2; exit 1; }
  echo "Starting upstream OpenCost inference-cost installer using existing Prometheus."
  echo "You will be prompted for infrastructure pricing; review it for your local/on-prem environment."
  "$COST_INSTALLER" \
    --prometheus-endpoint "http://prometheus.${NAMESPACE}.svc.cluster.local:9090" \
    --image "ghcr.io/opencost/opencost:develop-latest@sha256:e0c09b268d8243c45323fffec8ceea1434e9f7e982905af651b1adebfc7e3135"
  echo
  echo "Verify OpenCost metrics with:"
  echo "  sudo k8s kubectl port-forward -n llm-d-monitoring svc/opencost 9003:9003"
  echo "  curl -s http://localhost:9003/metrics | grep llm_"
  echo "Check Prometheus targets and ensure kube-state-metrics labels are exposed for llm-d.ai/model."
fi
