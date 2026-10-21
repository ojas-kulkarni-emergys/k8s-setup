# llm-d router and model deployment wizard

Files:
- `config.yaml`: central config; relative paths resolve relative to the config file.
- `templates/model-deployment.template.yaml`: editable Kubernetes Deployment + Service template used to generate model manifests.
- `llm-d-router.wizard.sh`: interactive router/model wizard.
- `llm_d_router.sh`: compatibility entry point forwarding to the wizard.

Requirements: `python3`, `python3-yaml`, `huggingface_hub` for model cache checking/downloading, `helm` for router option, and your `sudo k8s kubectl` command for cluster access.

Run from this directory or pass the config path explicitly:
```bash
chmod +x llm-d-router.wizard.sh llm_d_router.sh
./llm-d-router.wizard.sh ./config.yaml
```

Model cache behavior: the wizard uses `huggingface_hub.snapshot_download` with the configured HF cache and checks for a model's standard `models--org--repo` cache entry before downloading. It then generates a unique YAML file under `llm_d.generated_deployments_dir` and applies it after confirmation. Dataset cache entries are intentionally not offered as serving models.

Important: generated deployments mount the host cache with `hostPath`. This only works if Kubernetes pods run on a node with the same cache path and cached files. With multi-node clusters, preload the cache on every eligible node or change the design to a shared PVC. CPU-only memory/CPU presets are starting points, not guarantees; confirm the node has sufficient available RAM.

The selected vLLM image must support the model architecture and task. The wizard offers small generation models and embedding models; model-specific vLLM support can vary by image version.
