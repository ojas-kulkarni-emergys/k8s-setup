# Dashboard recommendations
# Dashboard	Recommendation	Why
# llm-d-router.json	Keep	Router and request-routing observability
# llm-d-vllm-overview.json	Keep	vLLM inference metrics
# llm-d-performance-kv-cache.json	Keep	KV-cache and inference performance, if the required metrics are exposed
# llm-d-failure-saturation-dashboard.json	Keep	Failure and saturation monitoring, if its Prometheus queries match your metrics
# llm-d-diagnostic-drilldown-dashboard.json	Optional	Troubleshooting and detailed diagnosis
# llm-d-sglang-overview.json	Optional	Only useful if you deploy SGLang
# llm-d-batch-gateway-apiserver.json	Skip for now	Batch gateway API-server metrics
# llm-d-batch-gateway-processor.json	Skip for now	Batch gateway processor metrics
# llm-d-batch-gateway-gc.json	Skip for now	Batch gateway garbage collection metrics
# llm-d-async-processor.json	Skip for now	Async processor metrics
# llm-d-pd-coordinator-metrics.json	Skip for now	Prefill/decode coordinator metrics, if that component is deployed
# llm-d-tpu-overview.json	Skip	TPU-specific monitoring

cd /home/ojas/hf/k8s-setup/k8s/node/observability

DASH_DIR="$PWD/grafana/dashboards"
SELECTED_DIR="$PWD/grafana/active-dashboards"

mkdir -p "$SELECTED_DIR"

for file in \
  llm-d-router.json \
  llm-d-vllm-overview.json \
  llm-d-performance-kv-cache.json \
  llm-d-failure-saturation-dashboard.json
do
  cp "$DASH_DIR/$file" "$SELECTED_DIR/"
done

sudo k8s kubectl create configmap llm-d-official-dashboards \
  -n observability-stack \
  --from-file="$SELECTED_DIR" \
  --dry-run=client -o yaml \
  > llm-d-official-dashboards.yaml

sudo k8s kubectl rollout restart deployment/grafana \
  -n observability-stack

sudo k8s kubectl apply -f /home/ojas/hf/k8s-setup/k8s/node/observability/observability-stack.yaml
sudo k8s kubectl apply -f /home/ojas/hf/k8s-setup/k8s/node/observability/llm-d-official-dashboards.yaml