#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root "IMPERMANENCE_PRESEED_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/prepare-impermanence-state.sh [--dry-run]

Pre-seed /persist with the paths declared in repo.impermanence.inventory so the
later persistence bind mounts already have canonical backing storage.

Examples:
  sudo ./scripts/prepare-impermanence-state.sh --dry-run
  sudo ./scripts/prepare-impermanence-state.sh
EOF
}

dry_run=false
case "${1:-}" in
  "")
    ;;
  --dry-run)
    dry_run=true
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

need nix jq rsync install dirname date

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

marker_root="/persist/appdata/.nixos-managed/impermanence-preseed-v1"
marker_file="${marker_root}/last-run"
timestamp="$(date --utc +%Y%m%dT%H%M%SZ)"

resolve_backing_path() {
  local path="$1"
  printf '/persist%s\n' "$path"
}

sync_directory() {
  local src="$1"
  local dest
  local verify_output=""

  dest="$(resolve_backing_path "$src")"
  echo "== directory =="
  echo "source:      $src"
  echo "destination: $dest"

  "${sudo_cmd[@]}" install -d -m 0755 "$(dirname "$dest")" "$dest"
  if [[ ! -d "$src" ]]; then
    echo "⚠️  source directory missing, leaving empty backing directory"
    return 0
  fi

  if $dry_run; then
    "${sudo_cmd[@]}" rsync -aHAX --numeric-ids --dry-run --itemize-changes "$src"/ "$dest"/
    return 0
  fi

  "${sudo_cmd[@]}" rsync -aHAX --numeric-ids "$src"/ "$dest"/
  verify_output="$("${sudo_cmd[@]}" rsync -nai --numeric-ids "$src"/ "$dest"/ || true)"
  if [[ -n "$verify_output" ]]; then
    echo "❌ verification drift for $src" >&2
    printf '%s\n' "$verify_output" >&2
    exit 1
  fi
}

sync_file() {
  local src="$1"
  local dest
  local verify_output=""

  dest="$(resolve_backing_path "$src")"
  echo "== file =="
  echo "source:      $src"
  echo "destination: $dest"

  "${sudo_cmd[@]}" install -d -m 0755 "$(dirname "$dest")"
  if [[ ! -e "$src" ]]; then
    echo "❌ source file missing: $src" >&2
    exit 1
  fi

  if $dry_run; then
    "${sudo_cmd[@]}" rsync -aHAX --numeric-ids --dry-run --itemize-changes "$src" "$dest"
    return 0
  fi

  "${sudo_cmd[@]}" rsync -aHAX --numeric-ids "$src" "$dest"
  verify_output="$("${sudo_cmd[@]}" rsync -nai --numeric-ids "$src" "$dest" || true)"
  if [[ -n "$verify_output" ]]; then
    echo "❌ verification drift for $src" >&2
    printf '%s\n' "$verify_output" >&2
    exit 1
  fi
}

mapfile -t persistence_directories < <(
  nix_json 'cfg.repo.impermanence.inventory.persistenceDirectories' | jq -r '.[]'
)
mapfile -t persistence_files < <(
  nix_json 'cfg.repo.impermanence.inventory.persistenceFiles' | jq -r '.[]'
)

echo "Preparing impermanence backing state under /persist"
if $dry_run; then
  echo "Mode: dry-run"
else
  "${sudo_cmd[@]}" install -d -m 0755 "$marker_root"
fi

for path in "${persistence_directories[@]}"; do
  sync_directory "$path"
done

for path in "${persistence_files[@]}"; do
  sync_file "$path"
done

if ! $dry_run; then
  printf '%s\n' "$timestamp" | "${sudo_cmd[@]}" tee "$marker_file" >/dev/null
fi

echo "✅ Impermanence preseed ${dry_run:+dry-run }completed."
