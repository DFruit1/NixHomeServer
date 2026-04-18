#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

usage() {
  cat <<'EOF'
Usage: scripts/restore-state.sh --target <path> [--snapshot <id|latest>] [--repo <path>] [--password-file <path>] [--include <prefix> ...]
EOF
}

nix_var() {
  local expr="$1"
  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

nix_config_attr() {
  local attr_path="$1"
  nix eval --raw ".#nixosConfigurations.$(nix_var 'vars.hostname').config.${attr_path}"
}

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

target=""
snapshot="latest"
repo="$(nix_var 'vars.backupRepository')"
password_file="$(nix_config_attr 'age.secrets.resticPassword.path')"
includes=()

while (($# > 0)); do
  case "$1" in
    --target)
      target="${2:-}"
      shift 2
      ;;
    --snapshot)
      snapshot="${2:-}"
      shift 2
      ;;
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --password-file)
      password_file="${2:-}"
      shift 2
      ;;
    --include)
      includes+=("${2:-}")
      shift 2
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
done

if [[ -z "$target" ]]; then
  usage >&2
  exit 1
fi

need find grep mkdir restic sort

if [[ -e "$target" ]]; then
  if find "$target" -mindepth 1 -print -quit | grep -q .; then
    echo "❌ Target path must be empty to keep restores non-destructive: $target" >&2
    exit 1
  fi
else
  mkdir -p "$target"
fi

restic_cmd=(restic --repo "$repo" --password-file "$password_file")

echo "ℹ️ Listing available restic snapshots from $repo…"
"${restic_cmd[@]}" snapshots

echo "ℹ️ Restoring snapshot '$snapshot' into $target…"
restore_cmd=("${restic_cmd[@]}" restore "$snapshot" --target "$target")
for prefix in "${includes[@]}"; do
  restore_cmd+=(--include "$prefix")
done
"${restore_cmd[@]}"

echo "✅ Restore completed. Restored top-level paths:"
find "$target" -mindepth 1 -maxdepth 1 -printf '  %P\n' | sort
