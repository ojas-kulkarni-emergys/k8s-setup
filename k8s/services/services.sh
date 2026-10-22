#!/usr/bin/env bash
# Independent services submenu: sudo bash services.sh [config.yaml]
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
init_config "${1:-}"
while true; do
  printf '\n=== Services ===\n1) Headlamp\n2) Recover images\n3) Docker registry (install / manage / status / logs)\n0) Back\n'
  read -r -p 'Select: ' choice || exit 0
  case "$choice" in
    1) bash "$(dirname -- "${BASH_SOURCE[0]}")/headlamp.sh" menu "$CONFIG" || echo 'Headlamp action failed.' >&2 ;;
    2) bash "$(dirname -- "${BASH_SOURCE[0]}")/pull-cluster-images.sh" || echo 'Image recovery failed.' >&2 ;;
    3) bash "$(dirname -- "${BASH_SOURCE[0]}")/docker-registry.sh" menu "$CONFIG" || echo 'Registry action failed.' >&2 ;;
    0) exit 0 ;; *) echo 'Invalid selection.' ;;
  esac
done
