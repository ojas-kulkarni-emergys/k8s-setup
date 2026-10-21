#!/usr/bin/env bash
set -Eeuo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$DIR/config.yml}"
export SETUP_ROLE_OVERRIDE=control
exec "$DIR/setup-cluster.sh" "$CONFIG"
