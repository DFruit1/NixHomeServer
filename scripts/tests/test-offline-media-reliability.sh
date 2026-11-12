#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools rg

# Retirement can otherwise lose recoverable enrollment/configuration data on
# an impermanent host. Keep retention coverage while replacing runtime probes
# for the removed daemon with absence checks.
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/syncthing"' \
  "Retiring sync must retain its persistent configuration and device identity."
require_fixed modules/offline-music/filepaths.nix '"d ${stateDir} 0750 root root -"' \
  "The existing enrollment archive must remain at its retained state path."
require_fixed modules/offline-music/backups.nix 'stateRoot = stateDir;' \
  "The retained enrollment archive must stay in the backup inventory."
forbid_match modules/Core_Modules/default.nix '[.]/syncthing' \
  "The retired daemon must no longer be imported."
forbid_match modules/Core_Modules/homepage/services.nix 'SYNCTHING|syncthing|offlineMediaEnroll|offlineMediaRemove|offlineMediaStatus' \
  "Homepage must not provision retired enrollment or API-key helpers."
forbid_match modules/offline-music/filepaths.nix 'syncthing|recursiveReadonlyGrants|rootTraverseGroups' \
  "Offline media must not grant filesystem access to the retired daemon."
forbid_match modules/offline-music/services.nix 'offline-media-reconcile|systemd[.]timers|ExecStart' \
  "Offline media must not schedule the retired reconciliation tooling."
require_fixed modules/Core_Modules/homepage/services.nix 'config.nixhomeserver.modules.filesync or false' \
  "Offline Media setup must follow File Sync availability."
require_fixed modules/Core_Modules/homepage/services.nix 'lib.unique [ "users" filesWebAccessGroup ]' \
  "File Sync guidance must require the existing Files permission without broadening access."
require_fixed custom_apps/node/apps/homepage/src/components/OfflineMediaSetup.tsx 'Set up File Sync' \
  "The service page must guide users through native File Sync setup."
require_fixed custom_apps/node/apps/filesync/src-tauri/plugins/tauri-plugin-mobile-files/android/src/main/java/BackgroundSync.kt 'NetworkType.UNMETERED' \
  "Native background syncing must stay on unmetered connections."
echo "✅ Offline Media retirement, retention and File Sync setup checks passed."
