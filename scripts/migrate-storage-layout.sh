#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

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

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

need nix rsync sudo date

data_root="$(nix_var 'vars.dataRoot')"
audiobooks_dir="$(nix_var 'vars.audiobookshelfDataDir')"
copyparty_exchange_dir="$(nix_var 'vars.sharedExchangeRoot')"
immich_managed_dir="$(nix_var 'vars.immichManagedPhotosRoot')"
jellyfin_dir="$(nix_var 'vars.jellyfinDataDir')"
kavita_dir="$(nix_var 'vars.kavitaDataDir')"
paperless_dir="$(nix_var 'vars.paperlessDataDir')"
paperless_consume_dir="$(nix_var 'vars.paperlessConsumeDir')"
paperless_archive_dir="$(nix_var 'vars.paperlessArchiveDir')"
paperless_export_dir="$(nix_var 'vars.paperlessExportDir')"
timestamp="$(date +%Y%m%d-%H%M%S)"

services_to_stop=(
  samba-smbd.service
  samba-nmbd.service
  oauth2-proxy.service
  copyparty.service
  immich-server.service
  immich-machine-learning.service
  paperless-web.service
  paperless-consumer.service
  paperless-scheduler.service
  paperless-task-queue.service
  audiobookshelf.service
  kavita.service
  jellyseerr.service
  jellyfin.service
)

mkdir_target() {
  sudo install -d -m 0755 "$1"
}

sync_dir() {
  local src="$1"
  local dst="$2"

  if [[ ! -d "$src" ]]; then
    echo "Skipping missing source: $src"
    return
  fi

  mkdir_target "$dst"
  echo "Syncing $src -> $dst"
  sudo rsync -aHAX --info=stats1,progress2 "$src"/ "$dst"/
}

backup_source() {
  local src="$1"

  if [[ ! -d "$src" ]]; then
    return
  fi

  local backup="${src}.bak-${timestamp}"
  if [[ -e "$backup" ]]; then
    echo "Backup path already exists: $backup" >&2
    exit 1
  fi

  echo "Renaming $src -> $backup"
  sudo mv "$src" "$backup"
}

echo "Stopping services before migration..."
for unit in "${services_to_stop[@]}"; do
  sudo systemctl stop "$unit" 2>/dev/null || true
done

mkdir_target "$(nix_var 'vars.appdataRoot')"
mkdir_target "$(nix_var 'vars.mediaRoot')"
mkdir_target "$(nix_var 'vars.workspaceRoot')"
mkdir_target "$(nix_var 'vars.usersWorkspaceRoot')"
mkdir_target "$(nix_var 'vars.sharedWorkspaceRoot')"
mkdir_target "$audiobooks_dir"
mkdir_target "$copyparty_exchange_dir"
mkdir_target "$immich_managed_dir"
mkdir_target "$jellyfin_dir"
mkdir_target "$kavita_dir"
mkdir_target "$paperless_dir"
mkdir_target "$paperless_consume_dir"
mkdir_target "$paperless_archive_dir"
mkdir_target "$paperless_export_dir"

sync_dir "${data_root}/audiobookshelf" "$audiobooks_dir"
sync_dir "${data_root}/copyparty" "${copyparty_exchange_dir}/legacy-import"
sync_dir "${data_root}/immich" "$immich_managed_dir"
sync_dir "${data_root}/jellyfin" "$jellyfin_dir"
sync_dir "${data_root}/kavita" "$kavita_dir"
sync_dir "${data_root}/paperless" "$paperless_dir"

if [[ -d "${data_root}/paperless/media" ]]; then
  sync_dir "${data_root}/paperless/media" "$paperless_archive_dir"
fi
if [[ -d "${data_root}/paperless/consume" ]]; then
  sync_dir "${data_root}/paperless/consume" "$paperless_consume_dir"
fi
if [[ -d "${data_root}/paperless/export" ]]; then
  sync_dir "${data_root}/paperless/export" "$paperless_export_dir"
fi

for src in \
  "${data_root}/audiobookshelf" \
  "${data_root}/copyparty" \
  "${data_root}/immich" \
  "${data_root}/jellyfin" \
  "${data_root}/kavita" \
  "${data_root}/paperless"
do
  backup_source "$src"
done

cat <<EOF

Migration complete.

Old directories were renamed with the suffix:
  .bak-${timestamp}

Post-migration checklist:
1. Run the documented rebuild command from AGENTS.md.
2. Add ${immich_managed_dir} as Immich managed storage and ${data_root}/media/photos/external as the external library root if needed.
3. Confirm Paperless is using:
   - consume: ${paperless_consume_dir}
   - archive: ${paperless_archive_dir}
   - export: ${paperless_export_dir}
4. Repoint Audiobookshelf, Kavita, and Jellyfin libraries in their UIs to the new media roots.
5. Validate Copyparty login, Jellyseerr setup, and NetBird-only SMB access before removing any .bak-* directories.
EOF
