# Terraform: Canonical Kubernetes + Gateway API Inference Extension + Helm

Terraform runs the existing node setup script first, then runs `scripts/deploy-helm.sh`. On a control-plane node, that script:

1. Checks the existing `inferencepools.inference.networking.k8s.io` CRD and lists Gateway API / Inference Extension CRDs.
2. Prints the first 100 lines of `llm-d/guides/env.sh` and searches `guides`, `hack`, `scripts`, and `Makefile` for GAIE install/version references.
3. Sources `guides/env.sh`, prints `GAIE_VERSION` and `GAIE_URL`, then applies `https://github.com/kubernetes-sigs/gateway-api-inference-extension/${GAIE_URL}/v1-manifests.yaml`.
4. Waits for the InferencePool CRD to be established.
5. Installs/updates the `headlamp`, `docker-registry`, `llm-d-router`, `distilgpt2`, `observability-stack`, and `reverse-kt` Helm releases.

The script detects `role: worker` in `config.yml` and skips the cluster-wide CRD/Helm stage on workers.

## Expected project layout

```text
k8s-setup/
├── config.yml
├── setup-cluster.sh
├── scripts/deploy-helm.sh
├── llm-d/                         # existing llm-d checkout, including guides/env.sh
├── k8s/node/helm/
│   ├── headlamp/
│   ├── docker-registry/
│   ├── llm-d-router/
│   ├── distilgpt2/
│   ├── observability-stack/
│   └── reverse-kt/
└── terraform/
    ├── main.tf
    └── terraform.tfvars
```

If your llm-d checkout is elsewhere, set `llm_d_repo` in `terraform.tfvars`. The default is `${project_dir}/llm-d`.

## First run

Run from Ubuntu/WSL on the control-plane machine. Review `config.yml` first; the existing setup script can configure VPN, change hostname, install Canonical Kubernetes, and enable addons.

```bash
cd /home/ojas/hf/k8s-setup
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Edit terraform/terraform.tfvars and set a strong Grafana password.
sudo -v
cd terraform
terraform init
terraform fmt -check
terraform validate
terraform plan
terraform apply
```

The required `grafana_admin_password` variable must be at least 12 characters. Instead of storing it in `terraform.tfvars`, set `TF_VAR_grafana_admin_password` in your shell before running Terraform. Do not commit secrets or the real `terraform.tfvars`.

Terraform's local-exec provisioners use `sudo -n`, so run `sudo -v` first. Helm is installed with Snap if it is missing and Snap is available.

## Manual reruns

Terraform provisioners run on resource creation/replacement. Chart/script changes update the chart hash and trigger the Helm stage, but changing the cluster setup script may also cause the setup resource to be replaced. To explicitly rerun only Helm deployment:

```bash
terraform apply -replace=terraform_data.helm_deployment
```

To run the Helm/GAIE stage without Terraform:

```bash
cd /home/ojas/hf/k8s-setup
sudo -v
sudo --preserve-env=GRAFANA_ADMIN_PASSWORD,LLM_D_REPO,HELM_DIR env \
  GRAFANA_ADMIN_PASSWORD='YOUR_STRONG_PASSWORD' \
  LLM_D_REPO=/home/ojas/hf/k8s-setup/llm-d \
  HELM_DIR=/home/ojas/hf/k8s-setup/k8s/node/helm \
  bash scripts/deploy-helm.sh config.yml
```

## Important prerequisites and notes

- This runs on the local machine; it does not copy scripts to or remotely configure other nodes.
- `llm-d/guides/env.sh` must define `GAIE_URL` and `GAIE_VERSION`.
- `reverse-kt` assumes its API/UI images are already pushed and accessible to Kubernetes. The chart uses NodePorts `30506` (UI) and `30507` (API), a 5Gi PVC, and the configured NFS server/path.
- The reverse-kt chart now points Prometheus and Grafana at the `observability-stack` namespace and mounts both its PVC cache and read-only shared NFS cache. Ensure the NFS server/path is reachable from the Kubernetes nodes.
- The docker-registry chart retains its source configuration (including NodePort 30500 and its configured ingress host). Adjust its values if those do not match your environment.
- Headlamp's source chart grants cluster-admin access. Expose it only in a trusted environment.
- The router chart requires the GAIE InferencePool CRD; the deployment script applies the GAIE manifests before installing the router chart.
- `terraform destroy` does not uninstall Kubernetes or the Helm releases.

# Kubernetes setup

`main.sh` is the menu orchestrator. It launches independent Bash modules; each
module can also be run directly. Settings are stored in `config.yaml`.

```bash
sudo bash /home/ojas/hf/k8s-setup/main.sh
```

`main.sh` is the only root shell entry point; the old `install.sh` alias was removed.

## Layout

```text
main.sh                                  Main menu and command dispatch
config.yaml                              Node, VPN, images, Headlamp and LLM settings
k8s/common.sh                            Shared YAML readers and config checks
k8s/cluster/setup-control-plane.sh        Install/bootstrap control plane and addons
k8s/cluster/setup-worker.sh               Install/join worker
k8s/cluster/vpn_manager.sh                VPN install, uninstall, active node address
k8s/cluster/node-manager.sh               Role dispatch, configuration, tokens and lifecycle menus
k8s/services/headlamp.sh                  Headlamp commands and submenu
k8s/services/pull-cluster-images.sh       Bounded normal pulls and --local fallback
vpn/                                     Provider-specific VPN installers and assets
k8s/node/llm-d.setup.sh                  Model/router entry point
k8s/node/llm-d/                           Config, deployment, workload Bash modules
k8s/node/manifests/                       Custom router, model and monitoring manifests
k8s/node/docker-registry.yaml             Docker registry resources
k8s/services/docker-registry.sh           Apply registry, status and logs
k8s/services/services.sh                  Services submenu
```

There is no Python service application or `k8s/lib/` directory. Service operations
are visible Bash commands. Small inline Python snippets parse YAML/JSON safely
and update config files; Python 3 and PyYAML remain prerequisites. Install PyYAML
with `sudo apt-get install python3-yaml`. Headlamp additionally requires Helm.

## Main menu

1. Node manager: configure, tokens, install control/worker, lifecycle and models
2. Install the configured VPN
3. Install Kubernetes for the configured control/worker role
4. Cluster start, stop, status and logs
5. Uninstall cluster, VPN or both
6. Services: Headlamp, image recovery, Docker registry
7. Models / llm-d router

VPN installation is separate from cluster installation. Set `role: control` or
`role: worker` and the VPN settings in `config.yaml` before installing. A worker
needs a token generated on the control plane. A role-specific installer refuses
a configuration for the other role. Connect the VPN before installing Kubernetes.
Relative VPN asset paths resolve against the supplied config file's directory.
Default config discovery works from any working directory.

## Independent commands

Control plane:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/cluster/setup-control-plane.sh
```

Worker (use this node's worker config):

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/cluster/setup-worker.sh /path/to/worker-config.yaml
```

VPN entry points:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/cluster/vpn_manager.sh install
sudo bash /home/ojas/hf/k8s-setup/k8s/cluster/vpn_manager.sh address
sudo bash /home/ojas/hf/k8s-setup/k8s/cluster/vpn_manager.sh uninstall
```

Each VPN command accepts an optional config path after its action. Uninstall asks
for the configured node name before removing the selected provider on this node.

Headlamp:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/services/headlamp.sh install
sudo bash /home/ojas/hf/k8s-setup/k8s/services/headlamp.sh forward
sudo bash /home/ojas/hf/k8s-setup/k8s/services/headlamp.sh token
sudo bash /home/ojas/hf/k8s-setup/k8s/services/headlamp.sh logs
sudo bash /home/ojas/hf/k8s-setup/k8s/services/headlamp.sh menu
```

An optional config filename follows the action. Installation uses the Canonical
cluster's credentials for Helm and returns after readiness. Forwarding binds
localhost:8080; Ctrl+C stops it. The token command creates a separate login account
with the configured `view` ClusterRole by default, plus a separate node-reader
role allowing only get/list/watch on nodes. Tokens expire after one hour.
`uninstall` removes the Helm release; the separate login account/binding remain.

Image recovery:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/services/pull-cluster-images.sh
sudo bash /home/ojas/hf/k8s-setup/k8s/services/pull-cluster-images.sh --local-only
```

The image-pull script is standalone: it does not read config.yaml or source
common.sh. Run on each node:
containerd caches are node-local. Normal pulls have a 5-minute budget, then retry
with `--local` for 20 minutes plus a 30-second termination grace. Budgets, runtime paths, and known image versions are written directly in the
script. Additional pod images are
collected from the API when available. Automatic recovery during cluster install
is disabled until `image_recovery.enabled` is true. It does not repair node routing
or Cilium configuration. The script includes a literal copy/paste pull example.

Direct orchestration options: `--configure`, `--controls`, `--install-vpn`,
`--uninstall-vpn`, `--install-cluster`, `--install-control`, `--install-worker`,
`--node-manager`, `--models`, `--services`, `--registry` (Docker registry submenu), `--worker-token`, `--start-cluster`,
`--stop-cluster`, `--cluster-status`, `--uninstall`, `--headlamp`, `--pull-images`.
An optional config path can accompany an option.

## Models

```bash
bash /home/ojas/hf/k8s-setup/k8s/node/llm-d.setup.sh
```

The model wizard reads `config.yaml`, manages models/router Deployments, restores
replica counts after stop/start, and provides logs. Background port forwards use
systemd services with restart and journal logs. Model caches use hostPath, so
eligible nodes need the same path and weights. Model downloads require
`huggingface_hub`.

## Offline verification

```bash
cd /home/ojas/hf/k8s-setup
python3 -m unittest discover -s tests -v
```

Tests run Bash modules against mocked host commands without changing the live
cluster. They cover service dispatch, role validation, VPN uninstall cancellation,
image discovery/timeout fallback, Headlamp install, and model lifecycle handling.

## Docker registry

From main.sh select Services > Docker registry > Install / apply manifest, or run:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/services/docker-registry.sh apply
sudo bash /home/ojas/hf/k8s-setup/k8s/services/docker-registry.sh status
sudo bash /home/ojas/hf/k8s-setup/k8s/services/docker-registry.sh logs
```

The apply command uses `k8s/node/docker-registry.yaml`. It preserves the manifest's
PVC and image settings and reports errors without deleting or recreating claims.
The `csi-rawfile-default` StorageClass must exist, with working storage node pods.
Registry application and readiness are separate; use status to check provisioning.

The four previous cluster installation files are consolidated into the two role
installers. Shared YAML readers remain in `k8s/common.sh`. To install according to
the configured role, use `main.sh --install-cluster` or the node-manager menu.

## Custom LLM manifests

`llm_d.manifests_dir`, `manifest_path`, `model_template_path`, and generated
model/output paths in `config.yaml` point to `k8s/node/manifests`. The upstream
`llm-d/` checkout is used only for Helm guide values and other upstream assets.
Custom resources are maintained outside that checkout.

In the LLM menu, select Deploy > Apply custom router / monitoring manifest.
Model manifests have their own existing/generated deployment options. Raw model
templates are excluded from the apply picker. Custom documents retain the
namespaces declared in YAML. Router, model, and monitoring manifests now use
`llm-d-deployments`. The hostPath cache paths
in model manifests still point to `/home/ojas/.cache/huggingface`: those refer to
model data on the node, not the old manifest directory.

Helm rendering writes `router/llm-d-router.rendered.yaml` separately from the custom
`router/llm-d-router.yaml`, and replaces the rendered output only after success.
The entry point loads `llm-d/config.sh`, `llm-d/workloads.sh`, and
`llm-d/deploy.sh`; run `llm-d.setup.sh` independently or through main.sh > Models.

## LLM namespace and release

```yaml
llm_d:
  namespace: llm-d-deployments
  release_name: llm-router
```

`release_name` replaces `guide_name`. Helm uses it as the release name, with the
namespace passed explicitly. Custom router resource names, RBAC references, EPP
pool arguments, model pool labels, headless-service selectors and service DNS are
aligned to `llm-router` and `llm-d-deployments`. Generated model templates use the
configured release name. Prometheus/Grafana manifests are in the same LLM namespace.
The Docker registry and Headlamp retain their separate namespaces.

These are file changes only. Applying the renamed manifests creates resources in
the new namespace; it does not migrate or delete workloads in the old namespace.
Custom YAML stores concrete names; keep it aligned when changing YAML config again.

## Registry management

Services > Docker registry has Install/apply and Manage options. Existing deployment
detection does not trigger reinstall. Management calls `k8s/node/registry_manager.sh`:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/node/registry_manager.sh catalog
sudo bash /home/ojas/hf/k8s-setup/k8s/node/registry_manager.sh tags my-image
sudo bash /home/ojas/hf/k8s-setup/k8s/node/registry_manager.sh delete my-image v1
sudo bash /home/ojas/hf/k8s-setup/k8s/node/registry_manager.sh gc
```

HTTP actions use `registry.url` in config.yaml. Start the registry's foreground
port forward in another terminal when using the default localhost URL. Deletion
requires confirmation and removes a manifest by digest, affecting any tags that
share that digest. Install/apply enables the registry's deletion API; an older
installation needs that manifest reapplied before deletion works. The GC action
is a dry-run preview, using registry v3's `/etc/distribution/config.yml`; actual GC
requires preventing writes and is not run by this menu. Append `--config FILE`
to registry-manager commands to use another config.

## Ingress configuration (no Bash modules)

Use [k8s/ingress/ingress.yaml](k8s/ingress/ingress.yaml) for standard ingress.
Tailscale Operator settings are separate in
[k8s/ingress/tailscale.values.yaml](k8s/ingress/tailscale.values.yaml).
The ingress scripts and menu action were removed. See the
[ingress README](k8s/ingress/README.md) for controller prerequisites, applying the
config, host/Windows DNS mapping, and optional Tailscale setup.