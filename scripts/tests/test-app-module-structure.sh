#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find rg sort

required_app_files=(
  backups.nix
  networking.nix
  identity.nix
  bootstrap.nix
  filepaths.nix
  services.nix
)

is_app_module_dir() {
  local dir_name="$1"

  case "$dir_name" in
    Core_Modules|power-management)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

while IFS= read -r module_dir; do
  module_name="${module_dir##*/}"
  is_app_module_dir "$module_name" || continue

  for required_file in "${required_app_files[@]}"; do
    if [[ ! -f "${module_dir}/${required_file}" ]]; then
      echo "❌ ${module_name} is missing ${required_file}."
      exit 1
    fi
  done

  if [[ ! -d "${module_dir}/integrations" ]]; then
    echo "❌ ${module_name} is missing an integrations directory."
    exit 1
  fi
done < <(find modules -mindepth 1 -maxdepth 1 -type d | sort)

if find modules -path '*/integrations/default.nix' -type f | rg -q .; then
  echo "❌ integrations/default.nix is ambiguous; import explicitly named integration modules instead."
  find modules -path '*/integrations/default.nix' -type f | sort
  exit 1
fi

if rg -n '^\s*\./integrations\s*$' modules/*/default.nix; then
  echo "❌ App defaults must import explicitly named integration modules, not ./integrations."
  exit 1
fi

echo "✅ App module structure tests passed."
