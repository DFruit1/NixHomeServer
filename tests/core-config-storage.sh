#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg

snapshot="$(nix_eval_host_snapshot_json '
  {
    vars = {
      dnsMode = vars.dnsMode;
      dnsPrivacyMode = vars.dnsPrivacyMode;
      zfsDataPoolName = vars.zfsDataPool.name;
      zfsDataPoolMirrorPairCount = builtins.length vars.zfsDataPool.mirrorPairs;
      zfsDataPoolDatasets = vars.zfsDataPool.datasets;
      zfsDataPoolDiskIds = vars.zfsDataPoolDiskIds;
      coldStoragePoolCount = builtins.length vars.coldStoragePools;
      coldStorageMountPoint = vars.coldStorageMountPoint;
      monitoredStorageDiskCount = builtins.length vars.monitoredStorageDiskIds;
      usersRoot = vars.usersRoot;
      sharedRoot = vars.sharedRoot;
      sharedAudiobooksRoot = vars.sharedAudiobooksRoot;
      sharedEmailsRoot = vars.sharedEmailsRoot;
      sharedEbooksRoot = vars.sharedEbooksRoot;
      sharedOtherBooksRoot = vars.sharedOtherBooksRoot;
      sharedMoviesRoot = vars.sharedMoviesRoot;
      sharedMusicVideosRoot = vars.sharedMusicVideosRoot;
      sharedYouTubeRoot = vars.sharedYouTubeRoot;
      sharedOtherVideosRoot = vars.sharedOtherVideosRoot;
      userBooksSubdirs = vars.userBooksSubdirs;
      userVideoSubdirs = vars.userVideoSubdirs;
      sharedBooksSubdirs = vars.sharedBooksSubdirs;
      sharedVideoSubdirs = vars.sharedVideoSubdirs;
      sharePhotosDomain = vars.sharePhotosDomain;
      metubeDomain = vars.metubeDomain;
      domain = vars.domain;
      kiwixLibraryRoot = vars.kiwixLibraryRoot;
    };
    config = {
      mailArchiveStoreRoot = cfg.services.mail-archive-ui.storeRoot;
      resticPaths = cfg.services.restic.backups.system-state.paths;
      resticRepository = cfg.services.restic.backups.system-state.repository;
      exfatSupport = cfg.boot.supportedFilesystems.exfat;
      fsPackages = cfg.system.fsPackages;
      dataFsType = cfg.fileSystems."/mnt/data".fsType;
      hasMediaMount = cfg.fileSystems ? "/mnt/data/media";
      hasUsersMount = cfg.fileSystems ? "/mnt/data/users";
      hasSharedMount = cfg.fileSystems ? "/mnt/data/shared";
      hasLegacyWorkspacesMount = cfg.fileSystems ? "/mnt/data/workspaces";
      hasLegacyMailArchiveMount = cfg.fileSystems ? "/mnt/data/mail-archive";
      persistNeededForBoot = cfg.fileSystems."/persist".neededForBoot;
      nixNeededForBoot = cfg.fileSystems."/nix".neededForBoot;
      hostId = cfg.networking.hostId;
      smartdEnable = cfg.services.smartd.enable;
      smartdDevices = cfg.services.smartd.devices;
      storageHealthTimer = cfg.systemd.timers."storage-health-report".timerConfig.OnCalendar;
      storageSmartShortDisk1 = cfg.systemd.timers."storage-smart-short@disk1".timerConfig.OnCalendar;
      storageSmartShortDisk2 = cfg.systemd.timers."storage-smart-short@disk2".timerConfig.OnCalendar;
      hasColdStorageSmartTimer = cfg.systemd.timers ? "storage-smart-short@cold-v1jan8ph";
      zfsAutoScrubEnable = cfg.services.zfs.autoScrub.enable;
    };
  }
')"

phase1_snapshot="$(nix_eval_host_snapshot_json_with_overrides \
  'repo.impermanence.enablePersistence = true;' \
  '
    {
      persistenceDirectories = map (entry: entry.directory) cfg.environment.persistence."/persist".directories;
      persistenceFiles = map (entry: entry.file) cfg.environment.persistence."/persist".files;
      resticPaths = cfg.services.restic.backups.system-state.paths;
    }
  '
)"

phase2_snapshot="$(nix_eval_host_snapshot_json_with_overrides \
  'repo.impermanence.enablePersistence = true; repo.impermanence.enableRootRollback = true;' \
  '
    {
      rootMountOptions = cfg.fileSystems."/".options;
      postResumeCommands = cfg.boot.initrd.postResumeCommands;
    }
  '
)"

snapshot_query() {
  jq -c "$1" <<<"$snapshot"
}

phase1_query() {
  jq -c "$1" <<<"$phase1_snapshot"
}

phase2_query() {
  jq -c "$1" <<<"$phase2_snapshot"
}

echo "ℹ️ Checking storage topology config values…"
require_json_equal "$(snapshot_query '.vars.dnsMode')" '"split-horizon"' \
  "vars.dnsMode must switch the host to split-horizon DNS."
require_json_equal "$(snapshot_query '.vars.dnsPrivacyMode')" '"encrypted-only"' \
  "vars.dnsPrivacyMode must keep the server on encrypted-only upstream DNS."
require_json_equal "$(snapshot_query '.vars.zfsDataPoolName')" '"data"' \
  "vars.zfsDataPool must keep the canonical pool name."
require_json_equal "$(snapshot_query '.vars.zfsDataPoolMirrorPairCount')" '1' \
  "vars.zfsDataPool must define one active mirror pair."
require_json_equal "$(snapshot_query '.vars.zfsDataPoolDatasets | length')" '3' \
  "vars.zfsDataPool must keep the expected child datasets."
require_json_contains "$(snapshot_query '.vars.zfsDataPoolDatasets')" 'media' \
  "vars.zfsDataPool must keep the media dataset."
require_json_contains "$(snapshot_query '.vars.zfsDataPoolDatasets')" 'users' \
  "vars.zfsDataPool must keep the direct users dataset."
require_json_contains "$(snapshot_query '.vars.zfsDataPoolDatasets')" 'shared' \
  "vars.zfsDataPool must keep the direct shared dataset."
forbid_json_contains "$(snapshot_query '.vars.zfsDataPoolDatasets')" 'workspaces' \
  "vars.zfsDataPool must retire the legacy workspaces dataset from steady-state config."
forbid_json_contains "$(snapshot_query '.vars.zfsDataPoolDatasets')" 'mail-archive' \
  "vars.zfsDataPool must retire the legacy mail-archive dataset from steady-state config."
forbid_json_contains "$(snapshot_query '.vars.zfsDataPoolDatasets')" 'appdata' \
  "vars.zfsDataPool must not retain the removed appdata dataset."
require_json_contains "$(snapshot_query '.vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V1JAKPNH" \
  "The ZFS data pool must include the healthiest disk."
require_json_contains "$(snapshot_query '.vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V1J9PKDH" \
  "The ZFS data pool must include the second good disk."
forbid_json_contains "$(snapshot_query '.vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V6G7R6MS" \
  "The ZFS data pool must leave the oldest healthy disk out as an offline spare."
forbid_json_contains "$(snapshot_query '.vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V1G5K8YC" \
  "The ZFS data pool must exclude the faulted disk."
forbid_match vars.nix 'enableBackups|enableBackup[D]isk|backup[D]isk|backupMount[P]oint|backupRe[p]ository' \
  "vars.nix must not retain the removed local-backup settings."
require_json_equal "$(snapshot_query '.vars.coldStoragePoolCount')" '0' \
  "vars.coldStoragePools must be empty when no manual cold-storage pool is attached."
require_json_equal "$(snapshot_query '.vars.coldStorageMountPoint')" '"/mnt/cold-storage"' \
  "vars.coldStorageMountPoint must keep the reserved optional mountpoint."
require_json_equal "$(snapshot_query '.vars.monitoredStorageDiskCount')" '2' \
  "The monitored storage disk list must include only the active mirror pair."
require_json_equal "$(snapshot_query '.vars.usersRoot')" '"/mnt/data/users"' \
  "Per-user content roots must resolve directly under the ZFS data pool."
require_json_equal "$(snapshot_query '.vars.sharedRoot')" '"/mnt/data/shared"' \
  "The shared content root must resolve directly under the ZFS data pool."
require_json_equal "$(snapshot_query '.vars.sharedAudiobooksRoot')" '"/mnt/data/shared/audiobooks"' \
  "Shared audiobooks must resolve through the shared public upload tree."
require_json_equal "$(snapshot_query '.vars.sharedEmailsRoot')" '"/mnt/data/shared/emails"' \
  "Shared mail archives must resolve through the shared content root."
require_json_equal "$(snapshot_query '.vars.sharedEbooksRoot')" '"/mnt/data/shared/books/ebooks"' \
  "Shared ebooks must resolve through the shared public upload tree."
require_json_equal "$(snapshot_query '.vars.sharedOtherBooksRoot')" '"/mnt/data/shared/books/other"' \
  "Shared other books must resolve through the shared public upload tree."
require_json_equal "$(snapshot_query '.vars.sharedMoviesRoot')" '"/mnt/data/shared/videos/movies"' \
  "Shared movies must resolve through the shared public upload tree."
require_json_equal "$(snapshot_query '.vars.sharedMusicVideosRoot')" '"/mnt/data/shared/videos/music-videos"' \
  "Shared music videos must resolve through the shared public upload tree."
require_json_equal "$(snapshot_query '.vars.sharedYouTubeRoot')" '"/mnt/data/shared/videos/youtube"' \
  "Shared YouTube videos must resolve through the shared public upload tree."
require_json_equal "$(snapshot_query '.vars.sharedOtherVideosRoot')" '"/mnt/data/shared/videos/other"' \
  "Shared other videos must resolve through the shared public upload tree."
require_json_contains "$(snapshot_query '.vars.userBooksSubdirs')" "ebooks" \
  "Per-user book roots must include ebooks."
require_json_contains "$(snapshot_query '.vars.userBooksSubdirs')" "other" \
  "Per-user book roots must include the fixed other category."
require_json_equal "$(snapshot_query '.vars.userVideoSubdirs')" '[]' \
  "Per-user video roots must be disabled."
require_json_contains "$(snapshot_query '.vars.sharedBooksSubdirs')" "other" \
  "Shared book roots must include the fixed other category."
require_json_contains "$(snapshot_query '.vars.sharedVideoSubdirs')" "movies" \
  "Shared video roots must include movies."
require_json_contains "$(snapshot_query '.vars.sharedVideoSubdirs')" "music-videos" \
  "Shared video roots must include music videos."
require_json_contains "$(snapshot_query '.vars.sharedVideoSubdirs')" "youtube" \
  "Shared video roots must include YouTube."
require_json_contains "$(snapshot_query '.vars.sharedVideoSubdirs')" "other" \
  "Shared video roots must include the fixed other category."
require_json_equal "$(snapshot_query '.config.mailArchiveStoreRoot')" '"/mnt/data/users"' \
  "Mail archive storage must resolve through the per-user content root."

restic_paths_json="$(snapshot_query '.config.resticPaths')"
require_json_contains "$restic_paths_json" "/var/lib" \
  "The system-state backup must include /var/lib for SSD-backed app state."
require_json_contains "$restic_paths_json" "/persist/appdata" \
  "The system-state backup must include /persist/appdata for SSD-backed app state."
forbid_json_contains "$restic_paths_json" "/persist" \
  "The default system-state backup must not switch to the /persist-only layout before persistence is enabled."
require_json_equal "$(snapshot_query '.config.resticRepository')" '"/mnt/backup-system-state/restic/system-state"' \
  "The system-state backup must target the runtime-selected external repository mount."
require_json_equal "$(snapshot_query '.config.exfatSupport')" 'true' \
  "The host must support exFAT backup media."
if ! printf '%s\n' "$(snapshot_query '.config.fsPackages')" | rg 'exfatprogs-[^"]*' >/dev/null; then
  echo "❌ The system filesystem packages must include exfatprogs for removable backup media."
  exit 1
fi

require_fixed modules/Core_Modules/restic-state/default.nix 'app-state-roots.tsv' \
  "The Restic metadata staging must emit an explicit app-state inventory."
require_fixed modules/Core_Modules/restic-state/default.nix '/var/lib/jellyfin' \
  "The Restic app-state inventory must cover Jellyfin."
require_fixed modules/Core_Modules/restic-state/default.nix '/persist/appdata/mail-archive-ui' \
  "The Restic app-state inventory must cover the mail archive UI."
require_fixed modules/Core_Modules/restic-state/default.nix '/persist/appdata/.nixos-managed/system-state-backup-target' \
  "The Restic module must persist the runtime-selected backup target under /persist/appdata/.nixos-managed."
require_fixed modules/Core_Modules/restic-state/default.nix 'scripts/backup-target.sh' \
  "The Restic module must orchestrate removable backup mounts through scripts/backup-target.sh."
require_fixed modules/Core_Modules/restic-state/default.nix 'persistent_state_root' \
  "The Restic app-state inventory must record the persistence backing path."
forbid_match modules/Core_Modules/restic-state/default.nix '/persist/backups/restic/system-state' \
  "The Restic module must not keep the old internal-SSD repository path as the active target."
forbid_match vars.nix 'appdataRoot|audiobookshelfDataDir|audiobookshelfConfigDir|audiobookshelfMetadataDir|audiobookshelfBackupDir|jellyfinDataDir|jellyfinLogDir|kavitaDataDir|paperlessDataDir|mailArchiveUiDataDir' \
  "vars.nix must not retain the old shared app-state path definitions."

echo "ℹ️ Checking data-disk stack extraction…"
require_fixed configuration.nix './modules/Core_Modules/storage-monitoring' \
  "configuration.nix must import the storage-monitoring module."
require_fixed configuration.nix './disko-system.nix' \
  "configuration.nix must import the SSD Disko layout separately from the data migration layout."
require_json_equal "$(snapshot_query '.config.dataFsType')" '"zfs"' \
  "The data pool must be mounted at /mnt/data as ZFS."
require_json_equal "$(snapshot_query '.config.hasMediaMount')" 'true' \
  "The media dataset mount must exist."
require_json_equal "$(snapshot_query '.config.hasUsersMount')" 'true' \
  "The users dataset mount must exist."
require_json_equal "$(snapshot_query '.config.hasSharedMount')" 'true' \
  "The shared dataset mount must exist."
require_json_equal "$(snapshot_query '.config.hasLegacyWorkspacesMount')" 'false' \
  "The legacy workspaces dataset mount must not remain in steady-state config."
require_json_equal "$(snapshot_query '.config.hasLegacyMailArchiveMount')" 'false' \
  "The legacy mail-archive dataset mount must not remain in steady-state config."
require_json_equal "$(snapshot_query '.vars.kiwixLibraryRoot')" '"/mnt/data/kiwix"' \
  "Kiwix must keep its dedicated top-level content root."
require_fixed flake.nix 'impermanence.url = "github:nix-community/impermanence";' \
  "The flake must import the impermanence input."
require_fixed configuration.nix './modules/Core_Modules/impermanence' \
  "configuration.nix must import the repo-local impermanence module."
forbid_match modules/Core_Modules/storage/layout.nix 'legacyAudiobooksRoot|legacyEbooksRoot|legacyComicsRoot|legacyMangaRoot|legacyOtherBooksRoot|legacyMoviesRoot|legacyShowsRoot|legacyHomeVideosRoot|legacyMusicVideosRoot|legacyYouTubeRoot|legacyOtherVideosRoot' \
  "The storage layout must not retain retired legacy media-root migration sources."
forbid_match modules/Core_Modules/storage/layout.nix 'path = "\$\{vars\.mediaRoot\}/audio";' \
  "The storage layout must not provision media/audio as a steady-state directory."
forbid_match modules/Core_Modules/storage/layout.nix 'path = "\$\{vars\.mediaRoot\}/books";' \
  "The storage layout must not provision media/books as a steady-state directory."
forbid_match modules/Core_Modules/storage/layout.nix 'path = "\$\{vars\.mediaRoot\}/video";' \
  "The storage layout must not provision media/video as a steady-state directory."
forbid_match modules/Core_Modules/storage/layout.nix 'path = podcastsRoot;' \
  "The storage layout must not provision the retired podcasts scaffold."
forbid_match modules/Core_Modules/restic-state/default.nix '"\$\{vars\.mediaRoot\}/audio"' \
  "The Restic inventory must not treat media/audio as canonical payload state."
forbid_match modules/Core_Modules/restic-state/default.nix '"\$\{vars\.mediaRoot\}/books"' \
  "The Restic inventory must not treat media/books as canonical payload state."
forbid_match modules/Core_Modules/restic-state/default.nix '"\$\{vars\.mediaRoot\}/video"' \
  "The Restic inventory must not treat media/video as canonical payload state."
require_fixed modules/Core_Modules/restic-state/default.nix 'vars.sharedAudiobooksRoot' \
  "The Restic inventory must treat shared audiobooks as canonical payload state."
require_fixed modules/Core_Modules/restic-state/default.nix 'vars.sharedBooksRoot' \
  "The Restic inventory must treat shared books as canonical payload state."
require_fixed modules/Core_Modules/restic-state/default.nix 'vars.sharedVideosRoot' \
  "The Restic inventory must treat shared videos as canonical payload state."
require_json_equal "$(snapshot_query '.config.persistNeededForBoot')" 'true' \
  "/persist must remain available in initrd before impermanence cutover."
require_json_equal "$(snapshot_query '.config.nixNeededForBoot')" 'true' \
  "/nix must remain available in initrd before impermanence cutover."

phase1_expected_directories_json="$(jq -cn '[
  "/etc/agenix",
  "/etc/ssh",
  "/home/dsaw",
  "/var/lib/acme",
  "/var/lib/audiobookshelf",
  "/var/lib/cloudflared",
  "/var/lib/copyparty",
  "/var/lib/immich-public-proxy",
  "/var/lib/jellyfin",
  "/var/lib/kanidm",
  "/var/lib/kavita",
  "/var/lib/kiwix",
  "/var/lib/metube",
  "/var/lib/netbird-main",
  "/var/lib/nixos",
  "/var/lib/paperless",
  "/var/lib/postgresql/16",
  "/var/lib/redis-immich",
  "/var/lib/redis-paperless",
  "/var/lib/storage-monitoring",
  "/var/lib/systemd/timers",
  "/var/lib/unbound",
  "/var/log/journal"
] | sort')"
require_json_equal "$(phase1_query '.persistenceDirectories | sort')" "$phase1_expected_directories_json" \
  "Phase 1 persistence must expose the exact declared directory inventory."
require_json_equal "$(phase1_query '.persistenceFiles | sort')" '["/etc/machine-id"]' \
  "Phase 1 persistence must expose the exact declared file inventory."
require_json_equal "$(phase1_query '.resticPaths')" '["/persist"]' \
  "Phase 1 Restic backups must switch to /persist as the canonical SSD-backed state root."

require_json_contains "$(phase2_query '.rootMountOptions')" 'subvol=root' \
  "Phase 2 must mount / from the dedicated root subvolume."
phase2_post_resume_commands="$(phase2_query '.postResumeCommands' | jq -r .)"
if [[ "$phase2_post_resume_commands" != *"root-blank"* ]]; then
  echo "❌ Phase 2 initrd rollback must reference the blank root snapshot."
  exit 1
fi
if [[ "$phase2_post_resume_commands" != *"old-roots"* ]]; then
  echo "❌ Phase 2 initrd rollback must rotate old roots through the old-roots directory."
  exit 1
fi

require_json_equal "$(snapshot_query '.config.hostId')" '"84e8c12a"' \
  "networking.hostId must be set for ZFS imports."
require_json_equal "$(snapshot_query '.config.smartdEnable')" 'true' \
  "SMART monitoring must remain enabled."
smartd_devices="$(snapshot_query '.config.smartdDevices')"
require_json_equal "$(printf '%s\n' "$smartd_devices" | jq 'length')" '2' \
  "smartd must monitor only the active mirror pair."
forbid_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726040ALA610_K7G5W29L" \
  "smartd must exclude the retired failing disk."
require_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1JAKPNH" \
  "smartd must monitor the healthiest pool disk."
require_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1J9PKDH" \
  "smartd must monitor the second healthy disk in the active mirror."
forbid_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V6G7R6MS" \
  "smartd must leave the offline spare out of the active monitoring set."
forbid_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1G5K8YC" \
  "smartd must exclude the faulted disk from the active monitoring set."
forbid_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726T4TALA6L4_V1JAN8PH" \
  "smartd must not monitor an unconfigured cold-storage disk."
require_json_equal "$(snapshot_query '.config.storageHealthTimer')" '"*:0/30"' \
  "Storage monitoring must generate the 30-minute report timer."
require_json_equal "$(snapshot_query '.config.storageSmartShortDisk1')" '"Sat *-*-* 03:00:00"' \
  "disk1 must keep the weekly short SMART schedule."
require_json_equal "$(snapshot_query '.config.storageSmartShortDisk2')" '"Sat *-*-* 03:20:00"' \
  "disk2 must keep the weekly short SMART schedule."
require_json_equal "$(snapshot_query '.config.hasColdStorageSmartTimer')" 'false' \
  "No cold-storage SMART timer should exist when no cold-storage pool is configured."
require_json_equal "$(snapshot_query '.config.zfsAutoScrubEnable')" 'true' \
  "ZFS auto-scrub must be enabled for the data pool."

require_fixed disko.nix 'vars.zfsDataPoolDiskIds' \
  "The data-only Disko file must source the active pool disks from vars.zfsDataPoolDiskIds."
forbid_match disko.nix 'vars\.mainDisk|vars\.coldStoragePools' \
  "The data-only Disko file must not reference the system SSD or manual cold-storage variables."
forbid_match disko.nix 'ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E|ata-HGST_HUS726T4TALA6L4_V1JAN8PH|ata-HGST_HUS726040ALA610_K7G5W29L' \
  "The data-only Disko file must exclude the SSD, the manual cold-storage disk, and the retired failing disk."
require_fixed scripts/format-system-disk.sh 'vars.mainDisk' \
  "The system-disk wrapper must source the target SSD from vars.mainDisk."
require_fixed scripts/format-data-disks.sh 'vars.zfsDataPoolDiskIds' \
  "The data-disk wrapper must source the target pool disks from vars.zfsDataPoolDiskIds."
forbid_match scripts/format-system-disk.sh 'disko-install\.nix' \
  "The system-disk wrapper must not reference the removed combined Disko path."
forbid_match scripts/format-data-disks.sh 'disko-install\.nix' \
  "The data-disk wrapper must not reference the removed combined Disko path."
forbid_match scripts/format-system-disk.sh 'ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E|ata-HGST_HUS726T4TALA6L4_V1JAKPNH|ata-HGST_HUS726T4TALA6L4_V6G7R6MS|ata-HGST_HUS726T4TALA6L4_V1J9PKDH|ata-HGST_HUS726T4TALA6L4_V1G5K8YC|ata-HGST_HUS726T4TALA6L4_V1JAN8PH' \
  "The system-disk wrapper must not hardcode current disk IDs."
forbid_match scripts/format-data-disks.sh 'ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E|ata-HGST_HUS726T4TALA6L4_V1JAKPNH|ata-HGST_HUS726T4TALA6L4_V6G7R6MS|ata-HGST_HUS726T4TALA6L4_V1J9PKDH|ata-HGST_HUS726T4TALA6L4_V1G5K8YC|ata-HGST_HUS726T4TALA6L4_V1JAN8PH' \
  "The data-disk wrapper must not hardcode current disk IDs."

echo "ℹ️ Checking cold-storage tooling…"
require_fixed modules/Core_Modules/storage/default.nix './import-fix.nix' \
  "The storage module must import the deterministic ZFS data-pool import override."
require_fixed modules/Core_Modules/storage/import-fix.nix '/dev/disk/by-id/${diskId}-part1' \
  "The ZFS data-pool import override must scope discovery to the configured member partitions."
require_fixed modules/Core_Modules/storage/import-fix.nix 'Pool $pool in state $state, waiting' \
  "The ZFS data-pool import override must keep the existing readiness loop semantics."
require_fixed modules/Core_Modules/storage/layout.nix 'coldStorageMountPoint' \
  "Storage tmpfiles must create the cold-storage mountpoint."
forbid_match modules/Core_Modules/storage/layout.nix 'data-pool-layout-migration-v2|retire_legacy_dataset_if_empty|move_categorized_tree|move_tree_contents|mailArchiveStoreRoot|legacyWorkspacesRoot|legacyUsersRoot|legacySharedRoot' \
  "Storage layout must not retain the retired layout-migration scaffolding."
forbid_match modules/Core_Modules/storage/default.nix './migrations.nix' \
  "The storage module must not import the retired app-state migration unit."
require_fixed scripts/cold-storage.sh 'Usage: scripts/cold-storage.sh <status|mount|unmount> [pool-name]' \
  "The cold-storage helper must expose named status, mount, and unmount commands."
require_fixed scripts/cold-storage.sh 'vars.coldStoragePools' \
  "The cold-storage helper must resolve pools from vars.nix."
require_fixed scripts/cold-storage.sh 'zpool import -N -d /dev/disk/by-id' \
  "The cold-storage helper must import pools without auto-mounting them."
require_fixed scripts/backup-target.sh 'Usage: scripts/backup-target.sh <list|status|select|mount|unmount|clear> [selector]' \
  "The backup-target helper must expose named list, status, select, mount, unmount, and clear commands."
require_fixed scripts/backup-target.sh '/persist/appdata/.nixos-managed/system-state-backup-target' \
  "The backup-target helper must persist its selection under /persist/appdata/.nixos-managed."
require_fixed scripts/backup-target.sh 'supported_fs_types=(exfat ext4 btrfs)' \
  "The backup-target helper must explicitly support exfat, ext4, and btrfs backup media."
require_fixed scripts/backup-target.sh 'vars.zfsDataPoolDiskIds' \
  "The backup-target helper must reject active data-pool disks from vars.zfsDataPoolDiskIds."
forbid_match scripts/backup-target.sh 'usb-Samsung_PSSD_T7' \
  "The backup-target helper must not hardcode any specific external USB device."

echo "✅ Storage core config tests passed."
