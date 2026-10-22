#!/usr/bin/env bash
# Independent development launcher. Intentionally NOT wired into existing main.sh.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
exec python3 -m pool_dashboard
