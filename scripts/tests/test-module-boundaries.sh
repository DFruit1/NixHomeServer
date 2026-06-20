#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools find rg sort

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
  [repo.seerr]=seerr
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
  [services.seerr]=seerr
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
