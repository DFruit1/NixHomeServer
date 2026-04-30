#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/retire-media-root.sh [--print-only|--yes]

Destroy or remove the legacy /mnt/data/media root after all services have moved
to the new /mnt/data/{paperless,immich} layout and the old root is empty.
EOF
}

print_only=false
run_now=false
case "${1:-}" in
  "")
    print_only=true
    ;;
  --print-only)
    print_only=true
    ;;
  --yes)
    run_now=true
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

need nix jq

config_json="$(
  nix_json '{
    dataRoot = vars.dataRoot;
    legacyMediaRoot = "${vars.dataRoot}/media";
    poolName = vars.zfsDataPool.name;
  }'
)"

data_root="$(jq -r '.dataRoot' <<<"$config_json")"
legacy_media_root="$(jq -r '.legacyMediaRoot' <<<"$config_json")"
pool_name="$(jq -r '.poolName' <<<"$config_json")"
legacy_dataset="${pool_name}/media"

echo "operation: retire legacy media root"
echo "data root: ${data_root}"
echo "legacy root: ${legacy_media_root}"
echo "legacy dataset: ${legacy_dataset}"
echo
echo "Commands to be run:"
echo "  sudo test -d ${legacy_media_root}"
echo "  sudo test -z \"\$(find ${legacy_media_root} -mindepth 1 -print -quit)\""
echo "  if zfs list ${legacy_dataset}; then sudo zfs destroy ${legacy_dataset}; else sudo rmdir ${legacy_media_root}; fi"

if [[ "$print_only" == true ]]; then
  exit 0
fi

if [[ "$run_now" != true ]]; then
  exit 1
fi

need sudo find

if [[ ! -d "$legacy_media_root" ]]; then
  echo "legacy root missing: ${legacy_media_root}" >&2
  exit 1
fi

if find "$legacy_media_root" -mindepth 1 -print -quit | grep -q .; then
  echo "legacy root is not empty: ${legacy_media_root}" >&2
  exit 1
fi

if sudo zfs list -H -o name "$legacy_dataset" >/dev/null 2>&1; then
  sudo zfs destroy "$legacy_dataset"
else
  sudo rmdir "$legacy_media_root"
fi
