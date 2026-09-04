#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find jq nix rg sed sort

# =========================================================================
# MODULE STRUCTURE VALIDATION
# =========================================================================

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
  nix eval --impure --json --expr 'builtins.attrNames (import ./modules/catalog.nix).apps' \
    | jq -r '.[]' \
    | sort
)"
if [[ "$expected_app_names" != "$configured_app_names" ]]; then
  echo "❌ modules/catalog.nix apps do not exactly match the application module directories."
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
  nix eval --impure --json --expr 'map builtins.baseNameOf (import ./modules/catalog.nix).integrations' \
    | jq -r '.[]' \
    | sort
)"
if [[ "$expected_integration_names" != "$configured_integration_names" ]]; then
  echo "❌ modules/catalog.nix integration imports do not exactly match modules/Integrations."
  diff -u \
    <(printf '%s\n' "$expected_integration_names") \
    <(printf '%s\n' "$configured_integration_names") || true
  exit 1
fi

echo "✅ App module structure tests passed."

# =========================================================================
# MODULE FACET BOUNDARY VALIDATION
# =========================================================================

# Verify each app module's default.nix only imports facets from within its own directory.
facet_violations=()
while IFS= read -r module_dir; do
  module_name="${module_dir##*/}"
  is_app_module_dir "$module_name" || continue

  while IFS= read -r import_path; do
    [[ -n "$import_path" ]] || continue
    case "$import_path" in
      ../*|./*/*)
        facet_violations+=("${module_name}/default.nix imports ${import_path}, which is outside the module directory.")
        ;;
    esac
  done < <(rg -oP '^\s+\K\./\S+' "${module_dir}/default.nix" || true)
done <<<"$module_dirs"

if ((${#facet_violations[@]} > 0)); then
  echo "❌ App module default.nix must only import facets from its own directory:"
  printf '   %s\n' "${facet_violations[@]}"
  exit 1
fi

echo "✅ App module facet boundary tests passed."

# =========================================================================
# CROSS-MODULE REFERENCE VALIDATION
# =========================================================================

# App modules must not reference sibling app internals; use modules/Integrations instead.
declare -A app_roots=(
  [repo.audiobookshelf]=audiobookshelf
  [repo.files]=files
  [repo.immich]=immich
  [repo.jellyfin]=jellyfin
  [repo.kavita]=kavita
  [repo.kiwix]=kiwix
  [repo.mailArchiveUi]=mail-archive-ui
  [repo.paperless]=paperless
  [repo.prowlarr]=prowlarr
  [repo.qbittorrent]=qbittorrent
  [repo.radarr]=radarr
  [repo.sonarr]=sonarr
  [repo.vaultwarden]=vaultwarden
  [repo.youtubeDownloader]=youtube-downloader
  [services.audiobookshelf]=audiobookshelf
  [services.filestash]=files
  [services.immich]=immich
  [services.jellyfin]=jellyfin
  [services.kavita]=kavita
  [services.mail-archive-ui]=mail-archive-ui
  [services.paperless]=paperless
  [services.prowlarr]=prowlarr
  [services.qbittorrent]=qbittorrent
  [services.radarr]=radarr
  [services.sonarr]=sonarr
  [services.vaultwarden]=vaultwarden
  [services.youtube-downloader]=youtube-downloader
)

violations=()

while IFS= read -r module_dir; do
  module_name="${module_dir##*/}"
  case "$module_name" in
    Core_Modules|Integrations)
      continue
      ;;
  esac

  while IFS= read -r match; do
    [[ -n "$match" ]] || continue

    root="$(sed -E 's/.*config\.((repo|services)\.[A-Za-z0-9_-]+).*/\1/' <<<"$match")"
    owner="${app_roots[$root]:-}"
    [[ -n "$owner" ]] || continue
    [[ "$owner" == "$module_name" ]] && continue

    violations+=("${match} references ${root}, owned by modules/${owner}")
  done < <(rg -n 'config\.((repo|services)\.[A-Za-z0-9_-]+)' "$module_dir" -g '*.nix' || true)
done < <(find modules -mindepth 1 -maxdepth 1 -type d | sort)

if ((${#violations[@]} > 0)); then
  echo "❌ App modules must not reference sibling app internals; use modules/Integrations instead."
  printf '   %s\n' "${violations[@]}"
  exit 1
fi

echo "✅ Module boundary tests passed."