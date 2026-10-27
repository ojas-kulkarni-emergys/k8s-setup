#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HELM_DIR="$ROOT/k8s/node/helm"
command -v helm >/dev/null || { echo "helm is required" >&2; exit 1; }
K=(sudo k8s kubectl)
"${K[@]}" get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1 || {
  echo "Missing InferencePool CRD. Install Gateway API Inference Extension CRDs first." >&2; exit 1;
}
helm upgrade --install headlamp "$HELM_DIR/headlamp" --namespace kube-system
helm upgrade --install docker-registry "$HELM_DIR/docker-registry" --namespace docker-registry --create-namespace
helm upgrade --install llm-d-router "$HELM_DIR/llm-d-router" --namespace llm-d-deployments --create-namespace
helm upgrade --install distilgpt2 "$HELM_DIR/distilgpt2" --namespace llm-d-deployments
if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  echo "Set GRAFANA_ADMIN_PASSWORD before installing observability, e.g.:"
  echo "  GRAFANA_ADMIN_PASSWORD='...' ./install-helm.sh --observability-only"
  exit 2
fi
helm upgrade --install observability-stack "$HELM_DIR/observability-stack" --namespace observability-stack --create-namespace --set-string grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD"
