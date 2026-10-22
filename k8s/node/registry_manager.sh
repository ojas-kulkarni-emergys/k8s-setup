#!/usr/bin/env bash
# sudo bash registry_manager.sh catalog|tags|delete|gc|menu [repository] [tag] [--config config.yaml]
# Start forwarding from Services > Docker registry first for HTTP API operations.
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/common.sh"
args=()
config=''
while (($#)); do
  case "$1" in
    --config) [[ $# -ge 2 ]] || { echo 'Missing config path.' >&2; exit 2; }; config="$2"; shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
init_config "$config"
set -- "${args[@]}"
validate_repo() {
  [[ "$1" =~ ^[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*$ ]] || { echo 'Invalid repository name.' >&2; return 2; }
}
case "${1:-menu}" in
  catalog)
    curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "$(cfg registry.url)/v2/_catalog" | python3 -m json.tool
    ;;
  tags)
    [[ $# -ge 2 ]] || { echo 'Usage: registry_manager.sh tags repository' >&2; exit 2; }
    validate_repo "$2"
    curl --fail --silent --show-error --connect-timeout 10 --max-time 30 "$(cfg registry.url)/v2/$2/tags/list" | python3 -m json.tool
    ;;
  delete)
    [[ $# -ge 3 ]] || { echo 'Usage: registry_manager.sh delete repository tag' >&2; exit 2; }
    validate_repo "$2"
    [[ "$3" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo 'Invalid tag.' >&2; exit 2; }
    headers="$(curl --fail --silent --show-error --head --connect-timeout 10 --max-time 30 \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
      "$(cfg registry.url)/v2/$2/manifests/$3")"
    digest="$(awk 'tolower($1)=="docker-content-digest:" {gsub("\r", "", $2); print $2}' <<< "$headers")"
    [[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'No valid manifest digest returned.' >&2; exit 1; }
    echo "Delete $2:$3 ($digest). Other tags pointing to the same digest are affected."
    read -r -p 'Type YES to delete this manifest: ' answer
    [[ "$answer" == YES ]] || exit 0
    code="$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' \
      -X DELETE "$(cfg registry.url)/v2/$2/manifests/$digest")"
    [[ "$code" == 202 ]] || { echo "Unexpected HTTP response: $code" >&2; exit 1; }
    echo 'Manifest deleted.'
    ;;
  gc)
    # Online garbage collection is preview-only; actual GC requires stopped writes.
    k8s kubectl exec -n "$(cfg registry.namespace)" "deployment/$(cfg registry.deployment)" -- \
      /bin/registry garbage-collect --dry-run "$(cfg registry.config_path)"
    ;;
  menu)
    while true; do
      printf '\n=== Registry contents ===\n1) List repositories\n2) List repository tags\n3) Delete manifest by tag\n4) Preview garbage collection (dry run)\n0) Back\n'
      read -r -p 'Select: ' choice || exit 0
      case "$choice" in
        1) bash "${BASH_SOURCE[0]}" catalog --config "$CONFIG" || echo 'Catalog failed; check port forwarding.' >&2 ;;
        2) read -r -p 'Repository: ' repo; bash "${BASH_SOURCE[0]}" tags "$repo" --config "$CONFIG" || echo 'Tags request failed.' >&2 ;;
        3) read -r -p 'Repository: ' repo; read -r -p 'Tag: ' tag; bash "${BASH_SOURCE[0]}" delete "$repo" "$tag" --config "$CONFIG" || echo 'Deletion failed.' >&2 ;;
        4) bash "${BASH_SOURCE[0]}" gc --config "$CONFIG" || echo 'GC preview failed.' >&2 ;;
        0) exit 0 ;; *) echo 'Invalid selection.' ;;
      esac
    done
    ;;
  *) echo 'Usage: registry_manager.sh [catalog|tags REPO|delete REPO TAG|gc|menu] [--config config.yaml]' >&2; exit 2 ;;
esac
