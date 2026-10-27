# Helm charts for the existing local Kubernetes setup

These charts were organized from the five manifests provided for this setup. They are under `k8s/node/helm/`. The templates mostly preserve the original manifests; the model chart is adjusted to use the CPU image and removes the invalid `--gpu-utilization` argument.

## Requirements

- Helm 3 and `sudo k8s kubectl` configured for the target cluster.
- The Gateway API Inference Extension CRDs must be installed before the llm-d router chart, including `inferencepools.inference.networking.k8s.io`.
- The cluster needs the `csi-rawfile-default` StorageClass for the registry PVC, or change `persistence.storageClassName`.
- The registry Ingress assumes a Cilium IngressClass and the configured hostname.
- The model chart uses hostPath `/home/ojas/.cache/huggingface` on the Kubernetes node; the path must exist on the node. The model needs to be present in the cache or downloadable by the pod.
- The observability manifest expects `llm-d-official-dashboards` ConfigMap and `llm-router-envoy-metrics` Service to be created elsewhere by the existing llm-d setup.

## Install order

Run from the repository root (adjust the path if you put this package elsewhere):

```bash
HELM_DIR="$PWD/k8s/node/helm"

# 1. Dashboard
sudo helm upgrade --install headlamp "$HELM_DIR/headlamp" \
  --namespace kube-system

# 2. Local registry (PVC + Ingress)
sudo helm upgrade --install docker-registry "$HELM_DIR/docker-registry" \
  --namespace docker-registry --create-namespace

# 3. llm-d router (requires InferencePool CRD)
sudo helm upgrade --install llm-d-router "$HELM_DIR/llm-d-router" \
  --namespace llm-d-deployments --create-namespace

# 4. Model backend. Review values and cache path first.
sudo helm upgrade --install distilgpt2 "$HELM_DIR/distilgpt2" \
  --namespace llm-d-deployments

# 5. Observability. Set a unique Grafana password before installing.
sudo helm upgrade --install observability-stack "$HELM_DIR/observability-stack" \
  --namespace observability-stack --create-namespace \
  --set-string grafana.adminPassword='REPLACE_WITH_A_STRONG_PASSWORD'

# 6. Reverse KT Demo 
sudo helm upgrade --install reverse-kt "$HELM_DIR/reverse-kt" \
  --namespace inference-demo
```

For a safer workflow, store the Grafana password in a protected values file outside version control rather than putting it on the command line.

## Validate before applying

```bash
for chart in k8s/node/helm/*; do
  helm lint "$chart" || exit 1
  helm template "$(basename "$chart")" "$chart" >/tmp/"$(basename "$chart")".rendered.yaml || exit 1
done
```

## Notes / limitations

- The Headlamp chart preserves the original `cluster-admin` binding. That is powerful access; consider a least-privilege role for routine use.
- The router chart contains a cluster-scoped ClusterRole and ClusterRoleBinding. Install only one release of this chart per cluster unless resource names are made release-specific.
- The registry chart keeps the original node affinity and NodePort. Adjust `nodeName` if the node name changes.
- The model chart lowers the memory request to `512Mi` and limit to `2Gi` to make scheduling more realistic on the local WSL node; this does not guarantee vLLM will fit within that limit. If it crashes, inspect pod logs and raise resources or use a smaller inference runtime/model.
- The charts are separated by original manifest. The router and model charts are installed into the same namespace, and the Service name `distilgpt2-service` is retained for the Prometheus scrape config.
