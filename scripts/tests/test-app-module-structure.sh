#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find rg sed sort

required_app_files=(
  backups.nix
  networking.nix
  identity.nix
  bootstrap.nix
  services.nix
)

is_app_module_dir() {
  local dir_name="$1"

  case "$dir_name" in
    Core_Modules|Integrations|power-management)
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

if ! module_dirs="$(find modules -mindepth 1 -maxdepth 1 -type d | sort)"; then
  echo "❌ Could not enumerate application module directories."
  exit 1
fi
while IFS= read -r module_dir; do
  module_name="${module_dir##*/}"
  is_app_module_dir "$module_name" || continue

  for required_file in "${required_app_files[@]}"; do
    if [[ ! -f "${module_dir}/${required_file}" ]]; then
      echo "❌ ${module_name} is missing ${required_file}."
      exit 1
    fi
  done

  if ! rg -q "nixhomeserver[.]modules[.]${module_name}[[:space:]]*=[[:space:]]*true" \
    "${module_dir}/default.nix"; then
    echo "❌ ${module_name} does not register itself in nixhomeserver.modules."
    exit 1
  fi

done <<<"$module_dirs"

expected_app_names="$(
  while IFS= read -r module_dir; do
    module_name="${module_dir##*/}"
    is_app_module_dir "$module_name" && printf '%s\n' "$module_name"
  done <<<"$module_dirs"
)"
configured_app_names="$(
  while IFS= read -r module_name; do
    is_app_module_dir "$module_name" && printf '%s\n' "$module_name"
  done < <(
    sed -n -E 's#^[[:space:]]*\./modules/([^/[:space:]]+)[[:space:]]*$#\1#p' configuration.nix \
      | sort
  )
)"
if [[ "$expected_app_names" != "$configured_app_names" ]]; then
  echo "❌ configuration.nix app imports do not exactly match the application module directories."
  diff -u <(printf '%s\n' "$expected_app_names") <(printf '%s\n' "$configured_app_names") || true
  exit 1
fi

if [[ ! -d modules/Integrations ]]; then
  echo "❌ modules/Integrations is missing."
  exit 1
fi

if find modules -mindepth 2 -maxdepth 2 -type d -name integrations | rg -q .; then
  echo "❌ App-level integrations directories are obsolete; use modules/Integrations instead."
  find modules -mindepth 2 -maxdepth 2 -type d -name integrations | sort
  exit 1
fi

if find modules/Integrations -name default.nix -type f | rg -q .; then
  echo "❌ modules/Integrations/default.nix is ambiguous; import explicitly named integration modules instead."
  find modules/Integrations -name default.nix -type f | sort
  exit 1
fi

if rg -n '^\s*\./integrations\s*$' modules/*/default.nix; then
  echo "❌ App defaults must import explicitly named integration modules, not ./integrations."
  exit 1
fi

if find modules/Integrations -maxdepth 1 -type f -name '*.nix' \
  | sed 's#^modules/Integrations/##' \
  | rg -v '^[a-z0-9]+(_[a-z0-9]+)+\.nix$'; then
  echo "❌ Integration module filenames should explicitly describe their relationship and purpose in snake_case."
  exit 1
fi

expected_integration_names="$(
  find modules/Integrations -maxdepth 1 -type f -name '*.nix' -printf '%f\n' \
    | sort
)"
configured_integration_names="$(
  sed -n -E \
    's#^[[:space:]]*\./modules/Integrations/([^/[:space:]]+[.]nix)[[:space:]]*$#\1#p' \
    configuration.nix \
    | sort
)"
if [[ "$expected_integration_names" != "$configured_integration_names" ]]; then
  echo "❌ configuration.nix integration imports do not exactly match modules/Integrations."
  diff -u \
    <(printf '%s\n' "$expected_integration_names") \
    <(printf '%s\n' "$configured_integration_names") || true
  exit 1
fi

echo "✅ App module structure tests passed."
