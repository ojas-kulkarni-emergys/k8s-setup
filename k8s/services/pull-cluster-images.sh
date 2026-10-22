#!/usr/bin/env bash
# Run on EACH node; caches are node-local.
# sudo bash pull-cluster-images.sh [--local-only]
# Literal command equivalent for one image (copy and paste):
# sudo timeout 20m /snap/k8s/current/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io images pull --local --platform linux/amd64 ghcr.io/canonical/cilium:1.18.4-ck0
set -Eeuo pipefail
umask 077
# Standalone: no config.yaml, common.sh, PyYAML, or environment overrides.
local_only=false
for arg in "$@"; do
  case "$arg" in
    --local-only) local_only=true ;;
    -h|--help) echo 'Usage: sudo bash pull-cluster-images.sh [--local-only]'; exit 0 ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
[[ -x /snap/k8s/current/bin/ctr ]] || { echo 'Canonical Kubernetes ctr is not installed.' >&2; exit 1; }
command -v timeout >/dev/null || { echo 'GNU timeout is required.' >&2; exit 1; }
case "$(uname -m)" in
  x86_64) platform=linux/amd64 ;; aarch64|arm64) platform=linux/arm64 ;;
  *) echo 'Unsupported architecture.' >&2; exit 2 ;;
esac
# Versions observed in this Canonical cluster; edit this list when upgrading.
# Each normal pull gets 5m; a failed/timed-out pull retries --local for 20m.
images='ghcr.io/canonical/cilium:1.18.4-ck0
ghcr.io/canonical/cilium-operator-generic:1.18.4-ck0
ghcr.io/canonical/rawfile-localpv:0.8.3-ck2
ghcr.io/canonical/csi-node-driver-registrar:2.15.0-ck0
ghcr.io/canonical/csi-provisioner:5.3.0-ck0
ghcr.io/canonical/csi-snapshotter:8.3.0-ck0'
# Optional API discovery also includes current app images and init containers.
if command -v python3 >/dev/null && pods="$(k8s kubectl get pods -A -o json --request-timeout=20s 2>/dev/null)"; then
  if discovered="$(python3 -c '
import json,sys
for pod in json.load(sys.stdin).get("items",[]):
    for field in ("containers","initContainers","ephemeralContainers"):
        for c in pod.get("spec",{}).get(field,[]) or []:
            if c.get("image"): print(c["image"])
' <<< "$pods")"; then
    images+=$'\n'"$discovered"
  else
    echo 'Could not parse pod images; using the built-in image list.' >&2
  fi
else
  echo 'Pod discovery unavailable; using the built-in image list.' >&2
fi
failed=()
while IFS= read -r image; do
  [[ -n "$image" ]] || continue
  echo "==> Pulling $image"
  if [[ "$local_only" == false ]]; then
    if timeout --kill-after=30s 5m \
      /snap/k8s/current/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io \
      images pull --platform "$platform" "$image"; then
      continue
    else
      echo "Normal pull failed/timed out (exit $?); retrying --local." >&2
    fi
  fi
  if timeout --kill-after=30s 20m \
    /snap/k8s/current/bin/ctr --address /run/containerd/containerd.sock --namespace k8s.io \
    images pull --local --platform "$platform" "$image"; then
    echo "Completed: $image"
  else
    echo "Local pull failed/timed out (exit $?): $image" >&2
    failed+=("$image")
  fi
done < <(printf '%s\n' "$images" | sort -u)
if ((${#failed[@]})); then
  printf 'Images still unavailable:\n' >&2
  printf '  %s\n' "${failed[@]}" >&2
  exit 1
fi
echo 'All requested image pulls completed on this node.'
