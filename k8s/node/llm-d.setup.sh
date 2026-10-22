#!/usr/bin/env bash
# Standalone: bash /home/ojas/hf/k8s-setup/k8s/node/llm-d.setup.sh [config.yaml]
# Menu entry point; implementation modules live in llm-d/ alongside this file.
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/llm-d/config.sh"
source "$SCRIPT_DIR/llm-d/workloads.sh"
source "$SCRIPT_DIR/llm-d/deploy.sh"

while management_menu; do
  set +e
  ( set -e; deploy_wizard )
  result=$?
  set -e
  if ((result != 0)); then echo "Deployment ended without completing; review the error above." >&2; fi
done
