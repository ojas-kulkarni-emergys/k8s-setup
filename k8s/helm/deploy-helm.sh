#!/usr/bin/env bash
set -Eeuo pipefail

# Install Gateway API Inference Extension CRDs, then deploy the local Helm charts.
# Run on the Canonical Kubernetes control-plane node.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-$ROOT/config.yml}"
HELM_DIR="${HELM_DIR:-$ROOT/k8s/node/helm}"
LLM_D_REPO="${LLM_D_REPO:-$ROOT/llm-d}"
K=(k8s kubectl)

if [[ $EUID -ne 0 ]]; then
  echo "Run as root (Terraform invokes this through sudo)." >&2
  exit 1
fi
[[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; exit 2; }
[[ -d "$HELM_DIR" ]] || { echo "Helm chart directory not found: $HELM_DIR" >&2; exit 2; }

# This deployment stage belongs on the control plane only.
ROLE="$(python3 - "$CONFIG" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    d = yaml.safe_load(f) or {}
print(d.get('role', 'control'))
PY
)"
if [[ "$ROLE" != "control" ]]; then
  echo "Node role is '$ROLE'; skipping cluster-wide CRD and Helm deployment on this worker."
  exit 0
fi

if [[ -z "${GRAFANA_ADMIN_PASSWORD:-}" ]]; then
  echo "GRAFANA_ADMIN_PASSWORD is required for the observability chart." >&2
  echo "Set it in terraform.tfvars or export TF_VAR_grafana_admin_password before terraform apply." >&2
  exit 2
fi

# Make Helm available if it is not already installed.
if ! command -v helm >/dev/null 2>&1; then
  command -v snap >/dev/null 2>&1 || { echo "Helm is missing and snap is unavailable; install Helm, then rerun." >&2; exit 1; }
  snap install helm --classic
fi
command -v helm >/dev/null

# Required diagnostics, matching the operator's requested checks.
echo "== Current InferencePool CRD =="
"${K[@]}" get crd inferencepools.inference.networking.k8s.io || true
echo "== Inference/Gateway API CRDs =="
"${K[@]}" get crd | grep -E 'inference.networking.k8s.io|gateway.networking.k8s.io' || true

[[ -d "$LLM_D_REPO" ]] || {
  echo "llm-d repo not found at: $LLM_D_REPO" >&2
  echo "Set LLM_D_REPO to the checkout containing guides/env.sh." >&2
  exit 2
}
cd "$LLM_D_REPO"
[[ -f guides/env.sh ]] || { echo "Missing $LLM_D_REPO/guides/env.sh" >&2; exit 2; }

echo "== guides/env.sh (first 100 lines) =="
sed -n '1,100p' guides/env.sh
echo "== GAIE references in guides/hack/scripts/Makefile =="
grep -RniE 'GAIE_URL|GAIE_VERSION|inference.*crd|install.*crd' guides hack scripts Makefile 2>/dev/null | head -100 || true

# Source upstream's version/url definitions and apply its matching manifest.
# shellcheck disable=SC1091
source guides/env.sh
: "${GAIE_VERSION:?guides/env.sh did not define GAIE_VERSION}"
: "${GAIE_URL:?guides/env.sh did not define GAIE_URL}"
echo "GAIE_VERSION=$GAIE_VERSION"
echo "GAIE_URL=$GAIE_URL"
"${K[@]}" apply -f "https://github.com/kubernetes-sigs/gateway-api-inference-extension/${GAIE_URL}/v1-manifests.yaml"

# Wait for the CRD used by llm-d-router to become established.
for _ in $(seq 1 60); do
  if "${K[@]}" get crd inferencepools.inference.networking.k8s.io >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
"${K[@]}" wait --for=condition=Established crd/inferencepools.inference.networking.k8s.io --timeout=300s

echo "== CRDs after applying GAIE manifests =="
"${K[@]}" get crd inferencepools.inference.networking.k8s.io
"${K[@]}" get crd | grep -E 'inference.networking.k8s.io|gateway.networking.k8s.io' || true

# Deploy in dependency order. CRDs are installed before the router chart.
helm upgrade --install headlamp "$HELM_DIR/headlamp" --namespace kube-system
helm upgrade --install docker-registry "$HELM_DIR/docker-registry" --namespace docker-registry --create-namespace
helm upgrade --install llm-d-router "$HELM_DIR/llm-d-router" --namespace llm-d-deployments --create-namespace
helm upgrade --install distilgpt2 "$HELM_DIR/distilgpt2" --namespace llm-d-deployments

helm upgrade --install observability-stack "$HELM_DIR/observability-stack" \
  --namespace observability-stack --create-namespace \
  --set-string grafana.adminPassword="$GRAFANA_ADMIN_PASSWORD"

helm upgrade --install reverse-kt "$HELM_DIR/reverse-kt" \
  --namespace inference-demo --create-namespace

echo "== Helm releases =="
helm list --all-namespaces
