#!/usr/bin/env bash
# Source this file, then call init_config [config.yaml].
init_config() {
  CONFIG="${1:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/config.yaml}"
  [[ "$CONFIG" = /* ]] || CONFIG="$PWD/$CONFIG"
  [[ -f "$CONFIG" ]] || { echo "Config not found: $CONFIG" >&2; return 2; }
  CONFIG_DIR="$(cd -- "$(dirname -- "$CONFIG")" && pwd)"
  [[ $EUID -eq 0 ]] || { echo 'Run this script with sudo.' >&2; return 1; }
  python3 -c 'import yaml' >/dev/null 2>&1 || {
    echo 'PyYAML required: sudo apt-get install python3-yaml' >&2; return 1;
  }
}
resolve_path() {
  [[ "$1" = /* ]] && printf '%s\n' "$1" || printf '%s/%s\n' "$CONFIG_DIR" "$1"
}
cfg() {
  python3 - "$CONFIG" "$1" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding="utf-8") as f:
    d = yaml.safe_load(f) or {}
for part in sys.argv[2].split("."):
    if not isinstance(d, dict) or part not in d:
        d = None
        break
    d = d[part]
if d is None:
    print("")
elif isinstance(d, bool):
    print("true" if d else "false")
elif isinstance(d, (dict, list)):
    print(yaml.safe_dump(d, default_flow_style=True).strip())
else:
    print(str(d))
PY
}

cfg_list() {
  python3 - "$CONFIG" "$1" <<'PYLIST'
import sys,yaml
with open(sys.argv[1]) as f: value=yaml.safe_load(f)
for part in sys.argv[2].split('.'): value=value[part]
if not isinstance(value,list): raise SystemExit('Expected YAML list')
for item in value:
    if not isinstance(item,str) or '\n' in item: raise SystemExit('Expected single-line strings')
    print(item)
PYLIST
}
