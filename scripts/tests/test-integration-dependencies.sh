#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find rg sort jq

# Each integration file maps to the app names it depends on.
# An integration is only meaningful when all of its listed apps are enabled.
declare -A integration_apps=(
  [expose_mail_archive_emails_in_files]="mail-archive-ui files"
  [grant_files_access_to_audiobookshelf_media]="files audiobookshelf"
  [grant_files_access_to_jellyfin_media]="files jellyfin"
  [grant_files_access_to_kavita_media]="files kavita"
  [grant_files_access_to_kiwix_library]="files kiwix"
  [remove_direct_mail_archive_access_from_paperless_inbox]="mail-archive-ui paperless"
  [send_mail_archive_documents_to_paperless]="mail-archive-ui paperless"
  [wait_for_audiobookshelf_storage_before_youtube_downloader]="audiobookshelf youtube-downloader"
  [wait_for_jellyfin_storage_before_youtube_downloader]="jellyfin youtube-downloader"
  [wire_media_automation_stack]="seerr sonarr radarr prowlarr qbittorrent jellyfin"
)

# Report any integration whose required apps are not all enabled.
# Host-specific: if kiwix, beszel, bonsai, or groundwater-logger are not enabled
# in this host, users should clean up the relevant integrations. The test warns
# but does not fail unless the operator has opted into strict mode.
strict_integration_deps="${NIXHOMESERVER_STRICT_INTEGRATION_DEPS:-0}"

# For host-specific enabled-apps validation, provide the list via env var.
enabled_apps_file="${NIXHOMESERVER_ENABLED_APPS_FILE:-}"
enabled_apps_list=""
if [[ -n "$enabled_apps_file" ]] && [[ -f "$enabled_apps_file" ]]; then
  enabled_apps_list="$(cat "$enabled_apps_file")"
fi

# 1. Verify every integration file in modules/Integrations/ is listed in catalog.nix,
#    and every catalog entry corresponds to an existing file.
actual_integration_files="$(find modules/Integrations -maxdepth 1 -type f -name '*.nix' -printf '%f\n' | sort)"
catalog_integration_files="$(rg -oP '\./Integrations/\K[^"]+\.nix' modules/catalog.nix | sort)"

if [[ "$actual_integration_files" != "$catalog_integration_files" ]]; then
  echo "❌ modules/Integrations/ files do not exactly match catalog.nix integration entries."
  diff <(echo "$actual_integration_files") <(echo "$catalog_integration_files") || true
  echo "   Keep catalog.nix integrations list in sync with files in modules/Integrations/."
  exit 1
fi

echo "✓ Integration file list matches catalog.nix."

# 2. Verify each integration references only well-known app names.
violations=()
while IFS= read -r file; do
  name="${file%.nix}"
  [[ -n "${integration_apps[$name]:-}" ]] && continue

  violations+=("modules/Integrations/${file} is missing from the integration_apps dependency map in this test script.")
done <<<"$catalog_integration_files"

if ((${#violations[@]} > 0)); then
  echo "❌ Integration dependency map is out of date:"
  printf '   %s\n' "${violations[@]}"
  exit 1
fi

# 3. When enabled-apps data is available, warn if an integration references apps
#    that are not enabled on the current host.
warnings=()
if [[ -z "$enabled_apps_list" ]]; then
  echo "⚠ Skipping per-host integration dependency check (enabled-apps data unavailable)."
else
  while IFS= read -r file; do
    name="${file%.nix}"
    required_apps="${integration_apps[$name]}"
    missing=""
    for app in $required_apps; do
      if ! echo "$enabled_apps_list" | tr ',' '\n' | grep -qx "$app"; then
        missing="$missing $app"
      fi
    done
    if [[ -n "$missing" ]]; then
      warnings+=("modules/Integrations/${file} requires$missing but one or more of these apps are not enabled on this host.")
    fi
  done <<<"$catalog_integration_files"

  if ((${#warnings[@]} > 0)); then
    if [[ "$strict_integration_deps" == "1" ]]; then
      echo "❌ Integrations reference disabled apps (strict mode):"
      printf '   %s\n' "${warnings[@]}"
      exit 1
    else
      echo "⚠ Integrations reference disabled apps (remove the integration if unwanted):"
      printf '   %s\n' "${warnings[@]}"
    fi
  fi
fi

echo "✅ Integration dependency checks passed."
