#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root "STORAGE_SMART_SWEEP_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/run-storage-smart-sweep.sh --kind short|long

Discover monitored storage devices and start SMART self-tests for each eligible
disk using the discovered transport arguments.
EOF
}

kind=""
while (($# > 0)); do
  case "$1" in
    --kind)
      kind="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$kind" in
  short|long)
    ;;
  *)
    echo "❌ --kind must be short or long." >&2
    exit 1
    ;;
esac

need jq smartctl

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
discovery_json_file="${tmpdir}/storage-discovery.json"

"$repo_root/scripts/discover-storage-devices.sh" --format json >"$discovery_json_file"

attempted=0
failed=0

while IFS= read -r disk_json; do
  [[ -n "$disk_json" ]] || continue
  label="$(jq -r '.label' <<<"$disk_json")"
  device="$(jq -r '.device' <<<"$disk_json")"
  mapfile -t smartctl_args < <(jq -r '.smartctlArgs // [] | .[]' <<<"$disk_json")

  attempted=$((attempted + 1))
  echo "Starting SMART ${kind} self-test for ${label}: ${device}"
  if smartctl "${smartctl_args[@]}" -t "$kind" "$device"; then
    :
  else
    failed=$((failed + 1))
    echo "⚠️  SMART ${kind} self-test request failed for ${label}: ${device}" >&2
  fi
done < <(jq -c '.allSmartDisks[]' "$discovery_json_file")

echo "SMART ${kind} sweep complete: attempted=${attempted} failed=${failed}"
