#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root "AUDIT_STORAGE_LAYOUT_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/audit-storage-layout.sh

Read-only audit for the current storage layout. It reports active payload roots,
retired legacy roots, and active SSD-backed app-state roots, and fails if any
retired root still contains data.

Example:
  sudo ./scripts/audit-storage-layout.sh
EOF
}

case "${1:-}" in
  "")
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

need nix jq find grep

root_prefix="${AUDIT_STORAGE_LAYOUT_ROOT_PREFIX:-}"
failed=0

resolve_path() {
  local path="$1"

  if [[ -n "$root_prefix" ]]; then
    printf '%s%s\n' "$root_prefix" "$path"
  else
    printf '%s\n' "$path"
  fi
}

path_has_entries() {
  local path="$1"
  local resolved

  resolved="$(resolve_path "$path")"
  [[ -d "$resolved" ]] || return 1
  find "$resolved" -mindepth 1 -print -quit | grep -q .
}

print_path_status() {
  local path="$1"
  local label="$2"
  local resolved

  resolved="$(resolve_path "$path")"
  if [[ -e "$resolved" ]]; then
    echo "✅ ${label}: ${path} (present)"
  else
    echo "⚠️  ${label}: ${path} (missing)"
  fi
}

mapfile -t active_payload_roots < <(
  nix_json 'cfg.repo.impermanence.inventory.activePayloadRoots' | jq -r '.[]'
)
mapfile -t retired_roots < <(
  nix_json 'cfg.repo.impermanence.inventory.retiredRoots' | jq -r '.[]'
)
mapfile -t active_app_state_roots < <(
  nix_json 'cfg.repo.impermanence.inventory.activeAppStateRoots' | jq -r '.[]'
)

echo "== Active Payload Roots =="
for path in "${active_payload_roots[@]}"; do
  print_path_status "$path" "active payload root"
done

echo
echo "== Retired Roots =="
for path in "${retired_roots[@]}"; do
  resolved="$(resolve_path "$path")"
  if [[ ! -e "$resolved" ]]; then
    echo "✅ retired root absent: ${path}"
    continue
  fi

  echo "⚠️  retired root present: ${path}"
  if path_has_entries "$path"; then
    echo "❌ retired root non-empty: ${path}"
    failed=1
  else
    echo "✅ retired root empty: ${path}"
  fi
done

echo
echo "== Active App State Roots =="
for path in "${active_app_state_roots[@]}"; do
  print_path_status "$path" "active app state root"
done

echo
if (( failed != 0 )); then
  echo "❌ Storage layout audit failed."
  exit 1
fi

echo "✅ Storage layout audit passed."
