#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/test-common.sh"

cd "$TESTS_REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/tests/test-evaluated-host-config.sh

Run one coarse evaluated host configuration pass for the active server config.
EOF
}

while (($# > 0)); do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  *)
    echo "❌ Unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

ensure_tools nix jq

export CORE_CONFIG_SNAPSHOT_JSON
CORE_CONFIG_SNAPSHOT_JSON="${CORE_CONFIG_SNAPSHOT_JSON:-$(nix_eval_host_snapshot_json '
{
vars = {
serverLanGateway = vars.serverLanGateway;
serverLanIP = vars.serverLanIP;
serverLanPrefixLength = vars.serverLanPrefixLength;
dataRoot = vars.dataRoot;
netIface = vars.netIface;
photosDomain = vars.photosDomain;
sharePhotosDomain = vars.sharePhotosDomain;
uploadsDomain = vars.uploadsDomain;
filebrowserDomain = vars.filebrowserDomain;
vaultwardenDomain = vars.vaultwardenDomain;
uploadSecurity = vars.uploadSecurity;
kanidmAdminUser = vars.kanidmAdminUser;
runtimeAccessCanaries = vars.runtimeAccessCanaries;
personalKavitaLibraries = vars.personalKavitaLibraries;
personalJellyfinLibraries = vars.personalJellyfinLibraries;
sharedJellyfinLibraries = vars.sharedJellyfinLibraries;
sharedJellyfinMusicLibraries = vars.sharedJellyfinMusicLibraries;
sharedBooksSubdirs = vars.sharedBooksSubdirs;
userContentSubdirs = vars.userContentSubdirs;
sharedContentSubdirs = vars.sharedContentSubdirs;
sharedMusicRoot = vars.sharedMusicRoot;
paperlessInboxRoot = vars.paperlessInboxRoot;
paperlessArchiveRoot = vars.paperlessArchiveRoot;
paperlessExportRoot = vars.paperlessExportRoot;
};
config = {
services = {
caddyEnable = cfg.services.caddy.enable;
cloudflaredEnable = cfg.services.cloudflared.enable;
unboundEnable = cfg.services.unbound.enable;
kanidmEnableServer = cfg.services.kanidm.enableServer;
netbirdAutostart = cfg.services.netbird.clients.myNetbirdClient.autoStart;
};
networking = {
gatewayAddress = cfg.networking.defaultGateway.address;
lanUseDhcp = cfg.networking.interfaces.${vars.netIface}.useDHCP;
lanAddresses = cfg.networking.interfaces.${vars.netIface}.ipv4.addresses;
lanAllowedTcpPorts = cfg.networking.firewall.interfaces.${vars.netIface}.allowedTCPPorts;
lanAllowedUdpPorts = cfg.networking.firewall.interfaces.${vars.netIface}.allowedUDPPorts;
nameservers = cfg.networking.nameservers;
};
sharedContentSubdirs = vars.sharedContentSubdirs;
fileSystems = {
hasDataMount = cfg.fileSystems ? "/mnt/data";
dataFsType = if cfg.fileSystems ? "/mnt/data" then cfg.fileSystems."/mnt/data".fsType else null;
persistNeededForBoot = cfg.fileSystems."/persist".neededForBoot;
nixNeededForBoot = cfg.fileSystems."/nix".neededForBoot;
persistedDirectories = cfg.repo.impermanence.inventory.persistenceDirectories;
hasLegacyWorkspacesMount = cfg.fileSystems ? "/mnt/data/workspaces";
hasLegacyMailArchiveMount = cfg.fileSystems ? "/mnt/data/mail-archive";
};
restic = {
repository = cfg.services.restic.backups.system-state.repository;
pathCount = builtins.length cfg.services.restic.backups.system-state.paths;
paths = cfg.services.restic.backups.system-state.paths;
backupPrepareCommand = cfg.services.restic.backups.system-state.backupPrepareCommand;
};
monitoring = {
hasSystemHealthService = cfg.systemd.services ? "system-health-report";
hasSystemHealthTimer = cfg.systemd.timers ? "system-health-report";
hasStorageSmartShortService = cfg.systemd.services ? "storage-smart-short";
hasStorageSmartLongService = cfg.systemd.services ? "storage-smart-long";
hasStorageSmartShortTimer = cfg.systemd.timers ? "storage-smart-short";
hasStorageSmartLongTimer = cfg.systemd.timers ? "storage-smart-long";
hasSmartdService = cfg.systemd.services ? "smartd";
systemHealthReportPath =
map (package: lib.getName package) (cfg.systemd.services."system-health-report".path or [ ]);
};
storage = {
zfsImportScript = cfg.systemd.services.zfs-import-data.script;
};
apps = {
caddyHostNames = builtins.attrNames cfg.services.caddy.virtualHosts;
caddyHostCount = builtins.length (builtins.attrNames cfg.services.caddy.virtualHosts);
cloudflaredIngressHostNames = builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
cloudflaredIngressCount = builtins.length (builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress);
oauthSystemNames = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2;
provisionGroupNames = builtins.attrNames cfg.services.kanidm.provision.groups;
provisionGroups = cfg.services.kanidm.provision.groups;
provisionPersonNames = builtins.attrNames cfg.services.kanidm.provision.persons;
provisionPersons = cfg.services.kanidm.provision.persons;
ageSecretNames = builtins.attrNames cfg.age.secrets;
mailArchiveUiEnable = cfg.services.mail-archive-ui.enable;
mailArchiveVisibleMirrorReadGroup = cfg.services.mail-archive-ui.visibleMirrorReadGroup;
hasMailArchiveOauth2ProxyService = cfg.systemd.services ? "mail-archive-oauth2-proxy";
mailArchiveOauth2ProxyExecStartPre =
cfg.systemd.services."mail-archive-oauth2-proxy".serviceConfig.ExecStartPre or [ ];
mailArchiveUiMountCondition =
cfg.systemd.services."mail-archive-ui".unitConfig.ConditionPathIsMountPoint or null;
mailArchiveUiEnvironment = cfg.services.mail-archive-ui.environment or { };
mailArchiveUiServiceEnvironment =
cfg.systemd.services."mail-archive-ui".serviceConfig.Environment or [ ];
mailArchiveUiReadWritePaths =
cfg.systemd.services."mail-archive-ui".serviceConfig.ReadWritePaths or [ ];
mailArchiveUiExtraGroups = cfg.users.users.mail-archive-ui.extraGroups or [ ];
mailArchiveUiPaperlessConsumeRoot = cfg.services.mail-archive-ui.paperlessConsumeRoot;
mailArchiveUiPath =
map (package: lib.getName package) (cfg.systemd.services."mail-archive-ui".path or [ ]);
mailArchiveSyncPath =
map (package: lib.getName package) (cfg.systemd.services."mail-archive-sync".path or [ ]);
hasCopypartyService = cfg.systemd.services ? "copyparty";
hasCopypartyRuntimeConfigSync = cfg.systemd.services ? "copyparty-runtime-config-sync";
hasUploadProcessorService = cfg.systemd.services ? "upload-processor";
hasUploadProcessorRescanService = cfg.systemd.services ? "upload-processor-rescan";
hasUploadProcessorRescanTimer = cfg.systemd.timers ? "upload-processor-rescan";
uploadProcessorReadWritePaths = cfg.systemd.services."upload-processor".serviceConfig.ReadWritePaths or [ ];
clamavDaemonEnable = cfg.services.clamav.daemon.enable;
clamavUpdaterEnable = cfg.services.clamav.updater.enable;
clamavDaemonSettings = cfg.services.clamav.daemon.settings;
hasGlancesService = cfg.systemd.services ? "glances";
hasGlancesOauth2ProxyService = cfg.systemd.services ? "glances-oauth2-proxy";
copypartyServiceSupplementaryGroups =
cfg.systemd.services.copyparty.serviceConfig.SupplementaryGroups or [ ];
copypartyServiceBindPaths =
cfg.systemd.services.copyparty.serviceConfig.BindPaths or [ ];
copypartyServiceReadWritePaths =
cfg.systemd.services.copyparty.serviceConfig.ReadWritePaths or [ ];
hasFilebrowserQuantumService = cfg.systemd.services ? "filebrowser-quantum";
hasFilebrowserQuantumAccessSync = cfg.systemd.services ? "filebrowser-quantum-access-sync-v1";
filebrowserQuantumExtraGroups = cfg.users.users.filebrowser-quantum.extraGroups or [ ];
filebrowserQuantumReadWritePaths =
cfg.systemd.services."filebrowser-quantum".serviceConfig.ReadWritePaths or [ ];
filebrowserQuantumAfter = cfg.systemd.services."filebrowser-quantum".after or [ ];
filebrowserQuantumWants = cfg.systemd.services."filebrowser-quantum".wants or [ ];
uploadProcessorRuntimeLayoutScript = cfg.systemd.services."upload-processor-runtime-layout".script or "";
systemdTmpfilesRules = cfg.systemd.tmpfiles.rules or [ ];
copypartySettings = cfg.services.copyparty.settings;
copypartyVolumes = cfg.services.copyparty.volumes;
copypartyPreStart = cfg.systemd.services.copyparty.preStart;
usersGroupMembers = cfg.users.groups.users.members or [ ];
hasImmichServerService = cfg.systemd.services ? "immich-server";
hasPaperlessWebService = cfg.systemd.services ? "paperless-web";
hasPaperlessPermissionsBootstrap = cfg.systemd.services ? "paperless-permissions-bootstrap";
paperlessPermissionsBootstrapScript = cfg.systemd.services.paperless-permissions-bootstrap.script;
paperlessSocialAccountSyncGroups = cfg.services.paperless.settings.PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS;
paperlessSocialAccountSyncGroupsClaim = cfg.services.paperless.settings.PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM;
hasOauth2ProxyService = cfg.systemd.services ? "oauth2-proxy";
oauth2ProxyExecStart = cfg.systemd.services.oauth2-proxy.serviceConfig.ExecStart;
hasAudiobookshelfLibrarySync = cfg.systemd.services ? "audiobookshelf-library-sync";
hasAudiobookshelfLibrarySyncTimer = cfg.systemd.timers ? "audiobookshelf-library-sync";
hasAudiobookshelfLibraryWatchConfig = cfg.systemd.services ? "audiobookshelf-library-watch-config-v1";
audiobookshelfLibraryWatchConfigScript =
cfg.systemd.services."audiobookshelf-library-watch-config-v1".script or "";
hasAudiobookshelfLibraryWatch = cfg.systemd.services ? "audiobookshelf-library-watch";
hasKavitaLibrarySync = cfg.systemd.services ? "kavita-library-sync";
hasKavitaLibrarySyncTimer = cfg.systemd.timers ? "kavita-library-sync";
hasKavitaMediaAclSync = cfg.systemd.services ? "kavita-media-acl-sync-v1";
hasKavitaLibraryWatch = cfg.systemd.services ? "kavita-library-watch";
hasKiwixLibraryWatch = cfg.systemd.services ? "kiwix-library-watch";
hasLegacyKiwixLibraryTimer = cfg.systemd.timers ? "kiwix-library-sync";
hasJellyfinLibraryMonitor = cfg.systemd.services ? "jellyfin-library-monitor-v1";
hasJellyfinLibraryBootstrap = cfg.systemd.services ? "jellyfin-library-bootstrap-v1";
jellyfinLibraryBootstrapScript = cfg.systemd.services."jellyfin-library-bootstrap-v1".script or "";
fileshareUserRootSyncScript = cfg.systemd.services."fileshare-user-root-sync".script or "";
jellyfinStorageLayoutScript = cfg.systemd.services."jellyfin-storage-layout-v1".script or "";
hasJellyfinLibrarySync = cfg.systemd.services ? "jellyfin-library-sync";
jellyfinLibrarySyncAfter = cfg.systemd.services.jellyfin-library-sync.after;
jellyfinLibrarySyncWants = cfg.systemd.services.jellyfin-library-sync.wants;
hasJellyfinLibraryWatch = cfg.systemd.services ? "jellyfin-library-watch";
jellyfinLibraryWatchAfter = cfg.systemd.services.jellyfin-library-watch.after;
jellyfinLibraryWatchWants = cfg.systemd.services.jellyfin-library-watch.wants;
hasYoutubeDownloaderService = cfg.systemd.services ? "youtube-downloader";
youtubeDownloaderEnvironment = cfg.systemd.services."youtube-downloader".environment or { };
youtubeDownloaderReadWritePaths =
cfg.systemd.services."youtube-downloader".serviceConfig.ReadWritePaths or [ ];
youtubeDownloaderPath =
map (package: lib.getName package) (cfg.systemd.services."youtube-downloader".path or [ ]);
metubeOauth2ProxyExecStart =
cfg.systemd.services."metube-oauth2-proxy".serviceConfig.ExecStart or "";
hasLegacyMetubeContainer =
cfg.environment.etc ? "containers/systemd/users/3002/metube.container";
hasMetubeAudioImport = cfg.systemd.services ? "metube-audio-import";
hasMetubeAudioImportWatch = cfg.systemd.services ? "metube-audio-import-watch";
jellyfinPayloadRoots = [
vars.sharedVideosRoot
vars.usersRoot
];
hasVaultwardenService = cfg.systemd.services ? "vaultwarden";
};
};
}
')}"

snapshot_query() {
  jq -c "$1" <<<"$CORE_CONFIG_SNAPSHOT_JSON"
}

assert_json_true() {
  local query="$1"
  local description="$2"

  require_json_equal "$(snapshot_query "$query")" "true" "$description"
}

assert_json_false() {
  local query="$1"
  local description="$2"

  require_json_equal "$(snapshot_query "$query")" "false" "$description"
}

echo "ℹ️ Checking coarse evaluated host configuration invariants…"

assert_json_true '.config.services.caddyEnable' "Caddy must remain enabled."
assert_json_true '.config.services.cloudflaredEnable' "Cloudflared must remain enabled."
assert_json_true '.config.services.unboundEnable' "Unbound must remain enabled."
assert_json_true '.config.services.kanidmEnableServer' "Kanidm must remain enabled."
assert_json_true '.config.services.netbirdAutostart' "NetBird must remain enabled."

require_json_equal "$(snapshot_query '.config.networking.gatewayAddress')" "$(snapshot_query '.vars.serverLanGateway')" \
  "The evaluated default gateway must follow vars.serverLanGateway."
assert_json_false '.config.networking.lanUseDhcp' "The primary LAN interface must remain statically configured."
require_json_equal "$(snapshot_query '.config.networking.lanAddresses[0].address')" "$(snapshot_query '.vars.serverLanIP')" \
  "The evaluated LAN address must follow vars.serverLanIP."
require_json_equal "$(snapshot_query '.config.networking.lanAddresses[0].prefixLength')" "$(snapshot_query '.vars.serverLanPrefixLength')" \
  "The evaluated LAN prefix length must follow vars.serverLanPrefixLength."
require_json_equal "$(snapshot_query '.config.networking.nameservers')" '["127.0.0.1"]' \
  "The host must keep using the local resolver."

lan_allowed_tcp_ports="$(snapshot_query '.config.networking.lanAllowedTcpPorts')"
if ! jq -e 'index(8096) != null' >/dev/null <<<"$lan_allowed_tcp_ports"; then
  echo "❌ The LAN firewall must allow Jellyfin direct access on TCP 8096."
  echo "   allowed TCP ports: $lan_allowed_tcp_ports"
  exit 1
fi

lan_allowed_udp_ports="$(snapshot_query '.config.networking.lanAllowedUdpPorts')"
if ! jq -e 'index(7359) != null' >/dev/null <<<"$lan_allowed_udp_ports"; then
  echo "❌ The LAN firewall must allow Jellyfin autodiscovery on UDP 7359."
  echo "   allowed UDP ports: $lan_allowed_udp_ports"
  exit 1
fi

assert_json_true '.config.fileSystems.hasDataMount' "The data mount must remain present."
require_json_equal "$(snapshot_query '.config.fileSystems.dataFsType')" '"zfs"' \
  "The data mount must remain backed by ZFS."
assert_json_true '.config.fileSystems.persistNeededForBoot' "The persist mount must remain needed for boot."
assert_json_true '.config.fileSystems.nixNeededForBoot' "The nix mount must remain needed for boot."
persisted_directories="$(snapshot_query '.config.fileSystems.persistedDirectories')"
for persisted_dir in /var/lib/copyparty /var/lib/clamav /var/lib/upload-processor /var/lib/filebrowser-quantum; do
  if ! jq -e --arg persisted_dir "$persisted_dir" 'index($persisted_dir) != null' >/dev/null <<<"$persisted_directories"; then
    echo "❌ Impermanence must persist ${persisted_dir}."
    echo "   persisted directories: $persisted_directories"
    exit 1
  fi
done
assert_json_false '.config.fileSystems.hasLegacyWorkspacesMount' "Legacy workspaces mounts must remain removed."
assert_json_false '.config.fileSystems.hasLegacyMailArchiveMount' "Legacy mail-archive mounts must remain removed."

require_json_equal "$(snapshot_query '.config.restic.repository')" '"/mnt/backup-system-state/restic/system-state"' \
  "System-state Restic backups must remain configured."
if [[ "$(snapshot_query '.config.restic.pathCount')" == "0" ]]; then
  echo "❌ System-state Restic backups must include at least one path."
  exit 1
fi
require_json_equal "$(snapshot_query '.config.restic.paths')" '["/persist"]' \
  "System-state Restic backups must stay scoped to persisted SSD-backed state."
if jq -e 'map(startswith("/mnt/data")) | any' >/dev/null <<<"$(snapshot_query '.config.restic.paths')"; then
  echo "❌ System-state Restic paths must not include data-pool payload content."
  echo "   paths: $(snapshot_query '.config.restic.paths')"
  exit 1
fi

restic_backup_prepare_command="$(snapshot_query '.config.restic.backupPrepareCommand' | jq -r '.')"
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'mail-archive-roots\.tsv' \
  "Backup preparation must write mail archive root metadata."
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'upload-flow-roots\.tsv' \
  "Backup preparation must write upload flow root metadata."
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'upload-staging.*upload-staging' \
  "Backup preparation must inventory upload staging."
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'upload-quarantine.*quarantine/uploads' \
  "Backup preparation must inventory upload quarantine."
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'mail-archive-ui\.sqlite3' \
  "Backup preparation must dump Mail Archive UI SQLite state when present."
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'upload-processor-state\.sqlite3' \
  "Backup preparation must dump upload processor SQLite state when present."
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'verify-attachments --repair --report' \
  "Backup preparation must verify and repair mail archive attachment blobs."
require_match modules/Core_Modules/restic-state/default.nix 'app = "upload-processor";' \
  "Upload processor state must be represented in backup app-state metadata."
require_match modules/Core_Modules/restic-state/default.nix 'vars\.uploadSecurity\.quarantineRoot' \
  "Backup policy must include quarantine root metadata coverage."
require_match modules/Core_Modules/restic-state/default.nix 'vars\.paperlessInboxRoot' \
  "Backup policy must include Paperless consume inbox metadata coverage."

assert_json_true '.config.monitoring.hasSystemHealthService' "System health reporting service must remain defined."
assert_json_true '.config.monitoring.hasSystemHealthTimer' "System health reporting timer must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartShortService' "SMART short sweep service must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartLongService' "SMART long sweep service must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartShortTimer' "SMART short sweep timer must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartLongTimer' "SMART long sweep timer must remain defined."
assert_json_true '.config.monitoring.hasSmartdService' "smartd must remain defined."
system_health_report_path="$(snapshot_query '.config.monitoring.systemHealthReportPath')"
if ! jq -e 'map(startswith("getent")) | any' >/dev/null <<<"$system_health_report_path"; then
  echo "❌ System health reporting service path must include getent for runtime readiness checks."
  echo "   path: $system_health_report_path"
  exit 1
fi

require_match <(printf '%s\n' "$(snapshot_query '.config.storage.zfsImportScript' | jq -r '.')") '-d /dev/disk/by-id' \
  "The ZFS import helper must scan the by-id directory generically."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.storage.zfsImportScript' | jq -r '.')") 'ata-HGST_HUS726T4TALA6L4' \
  "The ZFS import helper must not bake in stale pool-member disk IDs."

require_json_equal "$(snapshot_query '.config.apps.mailArchiveUiEnable')" "true" \
  "Mail archive UI must remain enabled."
assert_json_true '.config.apps.hasMailArchiveOauth2ProxyService' \
  "Mail archive OAuth2 Proxy wiring must remain present."
require_json_equal "$(snapshot_query '.config.apps.mailArchiveUiMountCondition')" "$(snapshot_query '.vars.dataRoot')" \
  "Mail archive UI must stay gated on the data mount."
require_json_equal "$(snapshot_query '.config.apps.mailArchiveVisibleMirrorReadGroup')" '"filebrowser-quantum"' \
  "Mail archive visible mirror read ACLs must target FileBrowser Quantum by default."

mail_archive_ui_path="$(snapshot_query '.config.apps.mailArchiveUiPath')"
if ! jq -e 'index("acl") != null' >/dev/null <<<"$mail_archive_ui_path"; then
  echo "❌ Mail archive UI service path must include acl tools for visible mirror read ACL repair."
  echo "   path: $mail_archive_ui_path"
  exit 1
fi

mail_archive_sync_path="$(snapshot_query '.config.apps.mailArchiveSyncPath')"
if ! jq -e 'index("acl") != null' >/dev/null <<<"$mail_archive_sync_path"; then
  echo "❌ Mail archive sync service path must include acl tools for visible mirror read ACL repair."
  echo "   path: $mail_archive_sync_path"
  exit 1
fi

mail_archive_oauth2_proxy_exec_start_pre="$(snapshot_query '.config.apps.mailArchiveOauth2ProxyExecStartPre')"
if [[ "$mail_archive_oauth2_proxy_exec_start_pre" == "[]" ]]; then
  echo "❌ Mail archive OAuth2 Proxy must wait for discovery and upstream readiness before starting."
  exit 1
fi

if ! jq -e 'map(test("mail-archive-oauth2-proxy-wait-for-discovery")) | any' >/dev/null <<<"$mail_archive_oauth2_proxy_exec_start_pre"; then
  echo "❌ Mail archive OAuth2 Proxy must wait for Kanidm OIDC discovery before startup."
  echo "   ExecStartPre: $mail_archive_oauth2_proxy_exec_start_pre"
  exit 1
fi

if ! jq -e 'map(test("mail-archive-oauth2-proxy-wait-for-upstream")) | any' >/dev/null <<<"$mail_archive_oauth2_proxy_exec_start_pre"; then
  echo "❌ Mail archive OAuth2 Proxy must wait for the Mail Archive UI upstream before startup."
  echo "   ExecStartPre: $mail_archive_oauth2_proxy_exec_start_pre"
  exit 1
fi

assert_json_true '.config.apps.hasCopypartyService' "Copyparty service wiring must remain present."
assert_json_true '.config.apps.hasFilebrowserQuantumService' "FileBrowser Quantum service wiring must remain present."
assert_json_true '.config.apps.hasFilebrowserQuantumAccessSync' "FileBrowser Quantum access convergence must remain present."

filebrowser_quantum_extra_groups="$(snapshot_query '.config.apps.filebrowserQuantumExtraGroups')"
if ! jq -e 'index("users") != null' >/dev/null <<<"$filebrowser_quantum_extra_groups"; then
  echo "❌ FileBrowser Quantum must keep users as a supplementary runtime group."
  echo "   extraGroups: $filebrowser_quantum_extra_groups"
  exit 1
fi
if jq -e 'index("mail-archive-ui") != null' >/dev/null <<<"$filebrowser_quantum_extra_groups"; then
  echo "❌ FileBrowser Quantum must not inherit mail-archive-ui write authority."
  echo "   extraGroups: $filebrowser_quantum_extra_groups"
  exit 1
fi
require_match modules/Core_Modules/storage/fileshare-user-roots.nix '\.internal-sync' \
  "User email roots must provision a hidden internal sync tree."
require_match modules/Core_Modules/storage/fileshare-user-roots.nix 'apply_directory_noaccess_acl filebrowser-quantum "\$root/emails/\.internal-sync"' \
  "FileBrowser Quantum must not be able to traverse the hidden internal email sync tree."
require_match modules/Core_Modules/storage/fileshare-user-roots.nix 'apply_writable_acl filebrowser-quantum' \
  "FileBrowser Quantum must receive writable ACLs on managed personal content roots."
require_match modules/Core_Modules/storage/fileshare-user-roots.nix '"\$root/files"' \
  "FileBrowser Quantum personal writable ACLs must include the files root."
forbid_match modules/audiobookshelf/storage.nix 'audiobookshelf-user-storage-acl-sync-v1' \
  "Audiobookshelf per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/filebrowser-quantum/storage.nix 'filebrowser-quantum-user-storage-acl-sync-v1' \
  "FileBrowser Quantum per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/immich/storage.nix 'immich-user-storage-acl-sync-v1' \
  "Immich per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/kavita/storage.nix 'kavita-media-acl-sync-v1' \
  "Kavita per-user ACL convergence must stay centralized in fileshare-user-root-sync."
require_match modules/kavita/storage.nix 'sharedKavitaAnonDirs = map \(library: "\$\{vars\.sharedBooksRoot\}/\$\{library\.dir\}/_Anon"\) vars\.sharedKavitaLibraries;' \
  "Kavita shared book libraries must create _Anon child directories so root-volume files are not ignored."
require_match modules/Core_Modules/storage/fileshare-user-roots.nix 'install -d -m 2770 -g users "\$root/books/\$name/_Anon"' \
  "Kavita per-user book libraries must create _Anon child directories so root-volume files are not ignored."
forbid_match modules/mail-archive-ui/storage.nix 'mail-archive-ui-user-storage-acl-sync-v1' \
  "Mail Archive UI per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/paperless/storage.nix 'paperless-user-storage-acl-sync-v1' \
  "Paperless per-user ACL convergence must stay centralized in fileshare-user-root-sync."
require_match scripts/helpers/runtime-health-common.sh 'allowedGroups = \[ "user-files" "shared-files-read-write-access" \];' \
  "Runtime health inventory must keep FileBrowser access scoped to file access groups only."
forbid_match modules/filebrowser-quantum/default.nix 'ensure_group_membership "mail-archive-users"' \
  "FileBrowser access convergence must not grant access from mail-archive-users alone."
require_match modules/filebrowser-quantum/default.nix 'ensure_deny_user "Personal" "/\$username/uploads" "\$username"' \
  "Personal FileBrowser access must deny legacy uploads."
require_match modules/filebrowser-quantum/default.nix 'ensure_deny_user "Personal" "/\$username/documents" "\$username"' \
  "Personal FileBrowser access must deny documents."
require_match modules/filebrowser-quantum/default.nix 'ensure_deny_user "Personal" "/\$username/photos" "\$username"' \
  "Personal FileBrowser access must deny photos."
forbid_match modules/filebrowser-quantum/default.nix 'name:"Uploads"' \
  "Personal FileBrowser sidebar must not expose Uploads."
require_match modules/filebrowser-quantum/default.nix 'name = "Quarantine"' \
  "FileBrowser Quantum must define a Quarantine source."
require_match modules/filebrowser-quantum/default.nix 'ensure_allow_group "Quarantine" "/" "app-admin"' \
  "Quarantine source must be scoped to app-admin."
filebrowser_quantum_extra_groups="$(snapshot_query '.config.apps.filebrowserQuantumExtraGroups')"
require_match <(printf '%s\n' "$filebrowser_quantum_extra_groups") 'upload-review' \
  "FileBrowser Quantum must have filesystem access to the quarantine review root."
filebrowser_quantum_read_write_paths="$(snapshot_query '.config.apps.filebrowserQuantumReadWritePaths')"
quarantine_root="$(snapshot_query '.vars.uploadSecurity.quarantineRoot' | jq -r '.')"
if ! jq -e --arg quarantine_root "$quarantine_root" 'index($quarantine_root) != null' >/dev/null <<<"$filebrowser_quantum_read_write_paths"; then
  echo "❌ FileBrowser Quantum must have a writable systemd sandbox path for upload quarantine."
  echo "   ReadWritePaths: $filebrowser_quantum_read_write_paths"
  exit 1
fi
for ordering_field in filebrowserQuantumAfter filebrowserQuantumWants; do
  if ! jq -e 'index("upload-processor-runtime-layout.service") != null' >/dev/null <<<"$(snapshot_query ".config.apps.${ordering_field}")"; then
    echo "❌ FileBrowser Quantum must order with upload-processor-runtime-layout.service through ${ordering_field}."
    exit 1
  fi
done
if ! jq -e --arg rule "d ${quarantine_root} 0770 upload-processor upload-review -" 'index($rule) != null' >/dev/null <<<"$(snapshot_query '.config.apps.systemdTmpfilesRules')"; then
  echo "❌ Upload quarantine root tmpfiles rule must be group-writable for upload-review."
  exit 1
fi
upload_processor_runtime_layout_script="$(snapshot_query '.config.apps.uploadProcessorRuntimeLayoutScript' | jq -r '.')"
require_match <(printf '%s\n' "$upload_processor_runtime_layout_script") 'chgrp -R upload-review' \
  "Upload processor runtime layout must normalize existing quarantine directory groups."
require_match <(printf '%s\n' "$upload_processor_runtime_layout_script") 'find .*quarantine/uploads.* -type d -exec chmod 0770' \
  "Upload processor runtime layout must normalize existing quarantine directories to group-writable."
forbid_match configuration.nix './modules/mail-archive-paperless' \
  "Mail Archive UI must not import the retired Paperless handoff module."

mail_archive_ui_environment="$(snapshot_query '.config.apps.mailArchiveUiEnvironment')"
if jq -e 'has("MAIL_ARCHIVE_UI_PAPERLESS_STAGING_DIR")' >/dev/null <<<"$mail_archive_ui_environment"; then
  echo "❌ Mail Archive UI extra environment must not expose Paperless staging paths."
  echo "   environment: $mail_archive_ui_environment"
  exit 1
fi

mail_archive_ui_service_environment="$(snapshot_query '.config.apps.mailArchiveUiServiceEnvironment')"
require_match <(printf '%s\n' "$mail_archive_ui_service_environment") 'MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT=' \
  "Mail Archive UI must explicitly expose the Paperless consume root for attachment handoff."
require_match <(printf '%s\n' "$mail_archive_ui_service_environment") "$(snapshot_query '.vars.paperlessInboxRoot' | jq -r '.')" \
  "Mail Archive UI Paperless handoff must use vars.paperlessInboxRoot."
require_json_equal "$(snapshot_query '.config.apps.mailArchiveUiPaperlessConsumeRoot')" "$(snapshot_query '.vars.paperlessInboxRoot')" \
  "Mail Archive UI Paperless consume root option must follow vars.paperlessInboxRoot."

mail_archive_ui_read_write_paths="$(snapshot_query '.config.apps.mailArchiveUiReadWritePaths')"
require_match <(printf '%s\n' "$mail_archive_ui_read_write_paths") "$(snapshot_query '.vars.paperlessInboxRoot' | jq -r '.')" \
  "Mail Archive UI ReadWritePaths must include Paperless consume root for attachment handoff."
if jq -e 'map(test("paperless") and test("staging")) | any' >/dev/null <<<"$mail_archive_ui_read_write_paths"; then
  echo "❌ Mail Archive UI ReadWritePaths must not include Paperless staging paths."
  echo "   ReadWritePaths: $mail_archive_ui_read_write_paths"
  exit 1
fi

mail_archive_ui_extra_groups="$(snapshot_query '.config.apps.mailArchiveUiExtraGroups')"
require_match <(printf '%s\n' "$mail_archive_ui_extra_groups") 'paperless' \
  "Mail Archive UI user must have paperless group access for consume-root handoff."

copyparty_service_supplementary_groups="$(snapshot_query '.config.apps.copypartyServiceSupplementaryGroups')"
if ! jq -e 'index("upload-staging") != null' >/dev/null <<<"$copyparty_service_supplementary_groups"; then
  echo "❌ Copyparty must declare upload-staging as a supplementary runtime group."
  echo "   SupplementaryGroups: $copyparty_service_supplementary_groups"
  exit 1
fi
if jq -e 'index("mail-archive-ui") != null' >/dev/null <<<"$copyparty_service_supplementary_groups"; then
  echo "❌ Copyparty must not keep legacy mail-archive-ui supplementary access."
  echo "   SupplementaryGroups: $copyparty_service_supplementary_groups"
  exit 1
fi

assert_json_true '.config.apps.hasImmichServerService' "Immich service wiring must remain present."
assert_json_true '.config.apps.hasPaperlessWebService' "Paperless service wiring must remain present."
assert_json_true '.config.apps.hasPaperlessPermissionsBootstrap' "Paperless permission bootstrap wiring must remain present."
require_json_equal "$(snapshot_query '.config.apps.paperlessSocialAccountSyncGroups')" '"true"' \
  "Paperless must keep OIDC group sync enabled."
require_json_equal "$(snapshot_query '.config.apps.paperlessSocialAccountSyncGroupsClaim')" '"groups"' \
  "Paperless must keep syncing OIDC groups from the groups claim."
assert_json_true '.config.apps.hasOauth2ProxyService' "OAuth2 Proxy service wiring must remain present."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.oauth2ProxyExecStart' | jq -r '.')") "--upstream-timeout='30m0s'" \
  "Uploads OAuth2 Proxy must allow long Copyparty upload handshakes and chunk posts."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.oauth2ProxyExecStart' | jq -r '.')") "--cookie-expire='720h0m0s'" \
  "Uploads OAuth2 Proxy must keep browser upload sessions valid beyond multi-day transfer estimates."
require_match modules/filebrowser-quantum/default.nix 'tokenExpirationHours = vars\.filebrowserTokenExpirationHours' \
  "FileBrowser Quantum must keep its web UI session lifetime declarative for long uploads."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.oauth2ProxyExecStart' | jq -r '.')") "--session-cookie-minimal=true" \
  "Uploads OAuth2 Proxy should keep repeated upload request cookies lean."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.oauth2ProxyExecStart' | jq -r '.')") "--skip-auth-preflight=true" \
  "Uploads OAuth2 Proxy should not force auth redirects for upload preflight requests."
assert_json_false '.config.apps.hasAudiobookshelfLibrarySync' "Audiobookshelf custom scan service must remain absent."
assert_json_false '.config.apps.hasAudiobookshelfLibrarySyncTimer' "Audiobookshelf custom scan timer must remain absent."
assert_json_true '.config.apps.hasAudiobookshelfLibraryWatchConfig' "Audiobookshelf native watcher convergence must remain present."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.audiobookshelfLibraryWatchConfigScript' | jq -r '.')") 'scannerDisableWatcher = false' \
  "Audiobookshelf must keep the global native watcher enabled."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.audiobookshelfLibraryWatchConfigScript' | jq -r '.')") 'disableWatcher = false' \
  "Audiobookshelf must keep per-library native watchers enabled."
assert_json_false '.config.apps.hasAudiobookshelfLibraryWatch' "Audiobookshelf must not use a separate recursive watcher service."
assert_json_false '.config.apps.hasKavitaLibrarySync' "Kavita settled scan service must remain absent."
assert_json_false '.config.apps.hasKavitaLibrarySyncTimer' "Kavita overnight scan timer must remain absent."
assert_json_false '.config.apps.hasKavitaMediaAclSync' "Kavita media ACL convergence must stay centralized in fileshare-user-root-sync."
assert_json_false '.config.apps.hasKavitaLibraryWatch' "Kavita recursive watcher service must remain absent."
require_match modules/kavita/default.nix 'disable-update-notifications\.patch' \
  "Kavita must keep in-app update notifications disabled; Nix owns application updates."
assert_json_true '.config.apps.hasKiwixLibraryWatch' "Kiwix watcher service must remain present."
assert_json_true '.config.apps.hasJellyfinLibraryMonitor' "Jellyfin library monitor config service must remain present."
assert_json_true '.config.apps.hasJellyfinLibraryBootstrap' "Jellyfin declarative library bootstrap must remain present."
assert_json_true '.config.apps.hasJellyfinLibrarySync' "Jellyfin settled scan service must remain present."
assert_json_true '.config.apps.hasJellyfinLibraryWatch' "Jellyfin recursive watcher service must remain present."
assert_json_true '.config.apps.hasYoutubeDownloaderService' "The custom YouTube downloader service must replace the MeTube container."
require_match configuration.nix '\./modules/youtube-downloader' \
  "The YouTube downloader service must be imported as its own module."
forbid_match modules/metube/default.nix '\./service\.nix' \
  "The MeTube module must not import the YouTube downloader service module."
if [[ -e modules/metube/service.nix ]]; then
  echo "❌ The YouTube downloader service must not live under modules/metube/service.nix."
  exit 1
fi
assert_json_false '.config.apps.hasLegacyMetubeContainer' "The legacy rootless MeTube container must not be active."
assert_json_false '.config.apps.hasMetubeAudioImport' "MeTube audio import service must stay retired; downloads now target final media roots directly."
assert_json_false '.config.apps.hasMetubeAudioImportWatch' "MeTube audio import watcher must stay retired; downloads now target final media roots directly."
youtube_downloader_env="$(snapshot_query '.config.apps.youtubeDownloaderEnvironment')"
require_json_equal "$(jq -c '.YOUTUBE_DOWNLOADER_DATABASE' <<<"$youtube_downloader_env")" '"/var/lib/metube/state/youtube-downloader.sqlite"' \
  "YouTube downloader state must use the persisted SQLite database path."
require_json_equal "$(jq -c '.YOUTUBE_DOWNLOADER_SHARED_WRITE_GROUP' <<<"$youtube_downloader_env")" '"shared-files-read-write-access"' \
  "YouTube downloader shared writes must use the existing shared-files Kanidm group."
require_json_equal "$(jq -c '.YOUTUBE_DOWNLOADER_SHARED_AUDIO_ROOT' <<<"$youtube_downloader_env")" '"/mnt/data/shared/audiobooks/youtube"' \
  "YouTube downloader shared audio must target the shared Audiobookshelf YouTube root."
youtube_downloader_readwrite="$(snapshot_query '.config.apps.youtubeDownloaderReadWritePaths')"
for rw_path in /var/lib/metube /var/cache/youtube-downloader /mnt/data/shared/videos/youtube /mnt/data/shared/audiobooks /mnt/data/users; do
  if ! jq -e --arg rw_path "$rw_path" 'index($rw_path) != null' >/dev/null <<<"$youtube_downloader_readwrite"; then
    echo "❌ YouTube downloader ReadWritePaths must include ${rw_path}."
    echo "   ReadWritePaths: $youtube_downloader_readwrite"
    exit 1
  fi
done
youtube_downloader_path="$(snapshot_query '.config.apps.youtubeDownloaderPath')"
for package_name in sqlite yt-dlp ffmpeg; do
  if ! jq -e --arg package_name "$package_name" 'map(startswith($package_name)) | any' >/dev/null <<<"$youtube_downloader_path"; then
    echo "❌ YouTube downloader service path must include ${package_name}."
    echo "   path: $youtube_downloader_path"
    exit 1
  fi
done
metube_oauth2_proxy_exec_start="$(snapshot_query '.config.apps.metubeOauth2ProxyExecStart' | jq -r '.')"
require_match <(printf '%s\n' "$metube_oauth2_proxy_exec_start") "'--api-route=\\^/api/'" \
  "YouTube downloader API fetches must receive 401 instead of starting competing OAuth2 PKCE flows."
persisted_directories="$(snapshot_query '.config.fileSystems.persistedDirectories')"
if ! jq -e 'index("/var/lib/metube") != null' >/dev/null <<<"$persisted_directories"; then
  echo "❌ Impermanence must persist /var/lib/metube for YouTube downloader SQLite state."
  echo "   persisted directories: $persisted_directories"
  exit 1
fi
require_match <(printf '%s\n' "$restic_backup_prepare_command") 'youtube-downloader\.sqlite' \
  "Backup preparation must dump the YouTube downloader SQLite state."
require_match node/apps/youtube-downloader/package.json '"packageManager": "pnpm@' \
  "YouTube downloader must pin pnpm as its package manager."
for forbidden in package-lock.json npm-shrinkwrap.json; do
  if [[ -e "node/apps/youtube-downloader/$forbidden" ]]; then
    echo "❌ YouTube downloader must not use ${forbidden}."
    exit 1
  fi
done
for file in node/apps/youtube-downloader/package.json node/apps/youtube-downloader/default.nix; do
  forbid_match "$file" '(^|[^[:alpha:]])npm([^[:alpha:]]|$)|buildNpmPackage' \
    "YouTube downloader must use pnpm workflows and avoid npm builders."
done
assert_json_true '.config.apps.hasUploadProcessorService' "Upload processor service wiring must be present."
assert_json_true '.config.apps.hasUploadProcessorRescanService' "Upload processor rescan service wiring must be present."
assert_json_true '.config.apps.hasUploadProcessorRescanTimer' "Upload processor rescan timer must be present."
assert_json_true '.config.apps.clamavDaemonEnable' "ClamAV daemon must be enabled."
assert_json_true '.config.apps.clamavUpdaterEnable' "ClamAV updater must be enabled."
assert_json_true '.config.apps.clamavDaemonSettings.AlertEncrypted' "ClamAV encrypted-file alerts must be enabled."
assert_json_true '.config.apps.clamavDaemonSettings.AlertEncryptedArchive' "ClamAV encrypted-archive alerts must be enabled."
assert_json_true '.config.apps.clamavDaemonSettings.AlertEncryptedDoc' "ClamAV encrypted-document alerts must be enabled."
if ! jq -e 'index("virusTotalApiKey") != null' >/dev/null <<<"$(snapshot_query '.config.apps.ageSecretNames')"; then
  echo "❌ Missing VirusTotal agenix secret definition: virusTotalApiKey."
  exit 1
fi
assert_json_false '.config.apps.hasGlancesService' "Glances service must be removed."
assert_json_false '.config.apps.hasGlancesOauth2ProxyService' "Glances OAuth2 Proxy service must be removed."
require_match scripts/helpers/upload-processor.sh '/api/v3/files/\$\{sha\}' \
  "Upload processor must use the VirusTotal hash lookup endpoint."
forbid_match scripts/helpers/upload-processor.sh '/api/v3/files/upload' \
  "Upload processor must never call the VirusTotal file upload endpoint."
forbid_match scripts/helpers/upload-processor.sh '/api/v3/files/upload_url' \
  "Upload processor must never call the VirusTotal upload URL endpoint."
assert_json_false '.config.apps.hasLegacyKiwixLibraryTimer' "Legacy Kiwix polling timer must remain absent."

shared_content_subdirs="$(snapshot_query '.config.sharedContentSubdirs')"
if ! jq -e 'index("files") != null and index("videos") != null and index("audiobooks") != null and index("books") != null and index("emails") != null and index("kiwix") != null and index("music") == null' >/dev/null <<<"$shared_content_subdirs"; then
  echo "❌ Shared content subdirectories must include files, videos, audiobooks, books, emails, and kiwix."
  echo "   sharedContentSubdirs: $shared_content_subdirs"
  exit 1
fi

user_content_subdirs="$(snapshot_query '.vars.userContentSubdirs')"
if ! jq -e 'index("files") != null and index("videos") != null and index("audiobooks") != null and index("books") != null and index("emails") != null' >/dev/null <<<"$user_content_subdirs"; then
  echo "❌ User content subdirectories must include files, videos, audiobooks, books, and emails."
  echo "   userContentSubdirs: $user_content_subdirs"
  exit 1
fi

jellyfin_payload_roots="$(snapshot_query '.config.apps.jellyfinPayloadRoots')"
jellyfin_shared_music_root="$(snapshot_query '.vars.sharedMusicRoot' | jq -r '.')"
if jq -e --arg root "$jellyfin_shared_music_root" 'index($root) != null' >/dev/null <<<"$jellyfin_payload_roots"; then
  echo "❌ Jellyfin payload roots must not include the shared music root."
  echo "   payloadRoots: $jellyfin_payload_roots"
  exit 1
fi

shared_jellyfin_libraries="$(snapshot_query '.vars.sharedJellyfinLibraries')"
personal_jellyfin_libraries="$(snapshot_query '.vars.personalJellyfinLibraries')"
shared_jellyfin_music_libraries="$(snapshot_query '.vars.sharedJellyfinMusicLibraries')"
expected_jellyfin_dirs='["movies","shows","home","music-videos","youtube"]'
if ! jq -e --argjson expected "$expected_jellyfin_dirs" 'map(.dir) == $expected' >/dev/null <<<"$shared_jellyfin_libraries"; then
  echo "❌ Shared Jellyfin libraries must be exactly movies, shows, home, music-videos, and youtube."
  echo "   sharedJellyfinLibraries: $shared_jellyfin_libraries"
  exit 1
fi
if jq -e 'map(.dir) | index("other") != null' >/dev/null <<<"$shared_jellyfin_libraries"; then
  echo "❌ Shared Jellyfin libraries must not include the retired other folder."
  echo "   sharedJellyfinLibraries: $shared_jellyfin_libraries"
  exit 1
fi
if ! jq -e --argjson shared "$shared_jellyfin_libraries" '. == $shared' >/dev/null <<<"$personal_jellyfin_libraries"; then
  echo "❌ Personal Jellyfin libraries must match shared Jellyfin libraries."
  echo "   personalJellyfinLibraries: $personal_jellyfin_libraries"
  echo "   sharedJellyfinLibraries: $shared_jellyfin_libraries"
  exit 1
fi
require_json_equal "$(jq 'length' <<<"$shared_jellyfin_music_libraries")" "0" \
  "Shared Jellyfin music libraries must be retired."
if ! jq -e 'index("jellyfin-users") != null' >/dev/null <<<"$(snapshot_query '.config.apps.provisionGroupNames')"; then
  echo "❌ Kanidm provisioning must include jellyfin-users when Jellyfin is enabled."
  exit 1
fi

jellyfin_storage_layout_script="$(snapshot_query '.config.apps.jellyfinStorageLayoutScript' | jq -r '.')"
for path in /mnt/data/shared/videos/movies /mnt/data/shared/videos/shows /mnt/data/shared/videos/home /mnt/data/shared/videos/music-videos /mnt/data/shared/videos/youtube; do
  require_match <(printf '%s\n' "$jellyfin_storage_layout_script") "$path" \
    "Jellyfin storage layout must create $path."
done
for forbidden_path in /mnt/data/shared/music /mnt/data/shared/videos/other; do
  forbid_match <(printf '%s\n' "$jellyfin_storage_layout_script") "$forbidden_path" \
    "Jellyfin storage layout must not create retired path $forbidden_path."
done

fileshare_user_root_sync_source="modules/Core_Modules/storage/fileshare-user-roots.nix"
require_match "$fileshare_user_root_sync_source" 'root/videos/\$name' \
  "Fileshare user root sync must create per-user Jellyfin video subdirectories."
for forbidden_path in 'videos/other' 'videos/music/youtube'; do
  forbid_match "$fileshare_user_root_sync_source" "$forbidden_path" \
    "Fileshare user root sync must not create retired per-user Jellyfin path $forbidden_path."
done

jellyfin_library_bootstrap_source="modules/jellyfin/library-bootstrap.nix"
jellyfin_library_bootstrap_script="$(snapshot_query '.config.apps.jellyfinLibraryBootstrapScript' | jq -r '.')"
for name in 'Shared Movies' 'Shared Shows' 'Shared Home Videos' 'Shared Music Videos' 'Shared YouTube'; do
  require_match <(printf '%s\n' "$jellyfin_library_bootstrap_script") "$name" \
    "Jellyfin bootstrap must use prefix shared library name $name."
done
for retired_name in 'Other Videos \(Shared\)' 'Shared Other Videos' 'YouTube Music \(Shared\)' 'Shared YouTube Music'; do
  require_match "$jellyfin_library_bootstrap_source" "$retired_name" \
    "Jellyfin bootstrap must know how to retire managed legacy library $retired_name."
done
for suffix_name in 'Movies \(Shared\)' 'Shows \(Shared\)' 'Home Videos \(Shared\)' 'Music Videos \(Shared\)' 'YouTube \(Shared\)'; do
  require_match <(printf '%s\n' "$jellyfin_library_bootstrap_script") "$suffix_name" \
    "Jellyfin bootstrap must know how to rename legacy shared library $suffix_name."
done

assert_json_false '.config.apps.hasCopypartyRuntimeConfigSync' "Copyparty must use the native module config renderer, not a duplicate runtime config sync service."
copyparty_volumes="$(snapshot_query '.config.apps.copypartyVolumes')"
if ! jq -e '
has("/${u}") and
(.["/${u}"].path | test("/upload-staging/\\$\\{u\\}$"))
' >/dev/null <<<"$copyparty_volumes"; then
  echo "❌ Copyparty must map each authenticated user to locked upload staging."
  echo "   volumes: $copyparty_volumes"
  exit 1
fi
if ! jq -e '.["/${u}"].access.w == "${u}" and (.["/${u}"].access.rwmd // null) == null' >/dev/null <<<"$copyparty_volumes"; then
  echo "❌ Copyparty must grant write-only upload access to the matching authenticated user."
  echo "   volumes: $copyparty_volumes"
  exit 1
fi
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.chmod_d')" '730' \
  "Copyparty should create locked staging directories."
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.chmod_f')" '660' \
  "Copyparty should keep uploaded files private to owner/group."
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.fk')" '4' \
  "Copyparty must keep filekeys enabled for upload-root files."
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.e2d')" 'true' \
  "Copyparty must keep the upload database enabled."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.xau' | jq -r '.')") 'f,j' \
  "Copyparty after-upload hook must be fire-and-forget and JSON-based."
copyparty_volume_json="$(jq -c '.' <<<"$copyparty_volumes")"
forbid_match <(printf '%s\n' "$copyparty_volume_json") '/upload/\$\{u\}' \
  "Copyparty must not require a per-user upload subpath on the uploads domain."
forbid_match <(printf '%s\n' "$copyparty_volume_json") 'rwmda' \
  "Copyparty must not expose admin controls on the uploads domain."
forbid_match <(printf '%s\n' "$copyparty_volume_json") '@domain_admins' \
  "Copyparty must not grant cross-user uploader access through domain_admins."
forbid_match <(printf '%s\n' "$copyparty_volume_json") '/shared/' \
  "Copyparty must retire shared browsing volumes."
forbid_match <(printf '%s\n' "$copyparty_volume_json") '/books/' \
  "Copyparty must retire book browsing volumes."
require_json_equal "$(snapshot_query '.config.apps.copypartySettings."s-tbody"')" '0' \
  "Copyparty runtime config must not apply a duplicate body timeout behind the reverse proxy."
require_json_equal "$(snapshot_query '.config.apps.copypartySettings."snap-drop"')" '10080' \
  "Copyparty runtime config must retain resumable upload state for week-long upload attempts."
require_json_equal "$(snapshot_query '.config.apps.copypartySettings.u2j')" '1' \
  "Copyparty runtime config must default the browser uploader to one chunk connection on slow paths."
require_json_equal "$(snapshot_query '.config.apps.copypartySettings.u2sz')" '"1,8,16"' \
  "Copyparty runtime config must default browser uploads to proxy-safe chunk sizes."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyPreStart' | jq -r '.')") 'copyparty -c /run/copyparty/copyparty.conf --exit cfg' \
  "Copyparty must validate the native module-rendered config before startup."
copyparty_bind_paths="$(snapshot_query '.config.apps.copypartyServiceBindPaths')"
require_match <(printf '%s\n' "$copyparty_bind_paths") '/upload-staging' \
  "Copyparty must bind only upload staging."
copyparty_read_write_paths="$(snapshot_query '.config.apps.copypartyServiceReadWritePaths')"
require_match <(printf '%s\n' "$copyparty_read_write_paths") '/upload-staging' \
  "Copyparty ReadWritePaths must include upload staging."
forbid_match <(printf '%s\n' "$copyparty_bind_paths") '/shared' \
  "Copyparty must not keep legacy shared-root filesystem exposure."
forbid_match <(printf '%s\n' "$copyparty_bind_paths") '/users' \
  "Copyparty must not bind user final files."
forbid_match <(printf '%s\n' "$copyparty_bind_paths") '/kiwix' \
  "Copyparty must not keep legacy Kiwix-library filesystem exposure."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_document" \
  "Paperless permission bootstrap must grant document view access to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "add_document" \
  "Paperless permission bootstrap must grant document create access to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "change_document" \
  "Paperless permission bootstrap must grant document edit access to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "delete_document" \
  "Paperless permission bootstrap must grant document delete access to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_tag" \
  "Paperless permission bootstrap must grant tag visibility to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_correspondent" \
  "Paperless permission bootstrap must grant correspondent visibility to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_documenttype" \
  "Paperless permission bootstrap must grant document type visibility to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_customfield" \
  "Paperless permission bootstrap must grant custom field visibility to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_storagepath" \
  "Paperless permission bootstrap must grant storage path visibility to paperless-users."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "view_paperlesstask" \
  "Paperless permission bootstrap must grant task visibility to paperless-users."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "add_group" \
  "Paperless permission bootstrap must not grant group creation to paperless-users."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "change_group" \
  "Paperless permission bootstrap must not grant group editing to paperless-users."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "add_user" \
  "Paperless permission bootstrap must not grant user creation to paperless-users."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "change_user" \
  "Paperless permission bootstrap must not grant user editing to paperless-users."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "add_workflow" \
  "Paperless permission bootstrap must not grant workflow creation to paperless-users."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.paperlessPermissionsBootstrapScript' | jq -r '.')") "change_appconfig" \
  "Paperless permission bootstrap must not grant application configuration editing to paperless-users."

if [[ "$(snapshot_query '.config.apps.caddyHostCount')" == "0" ]]; then
  echo "❌ Caddy must expose at least one virtual host."
  exit 1
fi

if [[ "$(snapshot_query '.config.apps.cloudflaredIngressCount')" == "0" ]]; then
  echo "❌ Cloudflared must expose at least one ingress entry."
  exit 1
fi

caddy_host_names="$(snapshot_query '.config.apps.caddyHostNames')"
if ! jq -e --arg photos_host "$(snapshot_query '.vars.photosDomain' | jq -r '.')" 'index($photos_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must keep the private Immich hostname configured."
  echo "   hosts: $caddy_host_names"
  exit 1
fi

if ! jq -e --arg file_host "$(snapshot_query '.vars.filebrowserDomain' | jq -r '.')" 'index($file_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must expose the private FileBrowser Quantum hostname."
  echo "   hosts: $caddy_host_names"
  exit 1
fi

if ! jq -e --arg uploads_host "$(snapshot_query '.vars.uploadsDomain' | jq -r '.')" 'index($uploads_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must expose the Copyparty uploader hostname."
  echo "   hosts: $caddy_host_names"
  exit 1
fi

if ! jq -e --arg share_host "$(snapshot_query '.vars.sharePhotosDomain' | jq -r '.')" 'index($share_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must keep the public Immich share hostname configured."
  echo "   hosts: $caddy_host_names"
  exit 1
fi

if ! jq -e --arg vaultwarden_host "$(snapshot_query '.vars.vaultwardenDomain' | jq -r '.')" 'index($vaultwarden_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must expose the private Vaultwarden hostname."
  echo "   hosts: $caddy_host_names"
  exit 1
fi

cloudflared_ingress_host_names="$(snapshot_query '.config.apps.cloudflaredIngressHostNames')"
if ! jq -e --arg share_host "$(snapshot_query '.vars.sharePhotosDomain' | jq -r '.')" 'index($share_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must publish the public Immich share hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

if jq -e --arg photos_host "$(snapshot_query '.vars.photosDomain' | jq -r '.')" 'index($photos_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must not publish the private Immich app hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

if jq -e --arg file_host "$(snapshot_query '.vars.filebrowserDomain' | jq -r '.')" 'index($file_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must not publish the private FileBrowser Quantum hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

if ! jq -e --arg uploads_host "$(snapshot_query '.vars.uploadsDomain' | jq -r '.')" 'index($uploads_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must publish the Copyparty uploader hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

if jq -e --arg vaultwarden_host "$(snapshot_query '.vars.vaultwardenDomain' | jq -r '.')" 'index($vaultwarden_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must not publish the private Vaultwarden hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

oauth_systems="$(snapshot_query '.config.apps.oauthSystemNames')"
if ! jq -e 'index("oauth2-proxy") != null and index("filebrowser-quantum-web") != null and index("immich-web") != null and index("paperless-web") != null and index("abs-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Expected OIDC-facing application registrations are missing from Kanidm provisioning."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi
if jq -e 'index("glances-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Glances must not be registered as a Kanidm OAuth2 client."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi
if jq -e 'index("vaultwarden-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Vaultwarden must not be registered as a Kanidm OAuth2 client."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi

provision_groups="$(snapshot_query '.config.apps.provisionGroupNames')"
if ! jq -e --arg admin "$(snapshot_query '.vars.kanidmAdminUser' | jq -r '.')" '.["shared-files-read-write-access"].members | index($admin) != null' >/dev/null <<<"$(snapshot_query '.config.apps.provisionGroups')"; then
  echo "❌ shared-files-read-write-access must include the Kanidm admin user for admin shared access."
  echo "   provisioned groups: $(snapshot_query '.config.apps.provisionGroups')"
  exit 1
fi
if jq -e 'index("glances-users") != null' >/dev/null <<<"$provision_groups"; then
  echo "❌ Kanidm provisioning must not define the removed Glances access group."
  echo "   provisioned groups: $provision_groups"
  exit 1
fi
if jq -e 'index("vaultwarden-users") != null or index("vaultwarden-user") != null' >/dev/null <<<"$provision_groups"; then
  echo "❌ Kanidm provisioning must not define Vaultwarden access groups for local-auth Vaultwarden."
  echo "   provisioned groups: $provision_groups"
  exit 1
fi

runtime_canaries="$(snapshot_query '.vars.runtimeAccessCanaries')"
provision_person_names="$(snapshot_query '.config.apps.provisionPersonNames')"
if ! jq -e 'keys == ["canary-files"]' >/dev/null <<<"$runtime_canaries"; then
  echo "❌ vars.runtimeAccessCanaries must define exactly one runtime canary: canary-files."
  echo "   runtimeAccessCanaries: $runtime_canaries"
  exit 1
fi

if ! jq -e 'index("canary-files") != null' >/dev/null <<<"$provision_person_names"; then
  echo "❌ Kanidm provisioning must declare canary-files."
  echo "   provisioned persons: $provision_person_names"
  exit 1
fi

if ! jq -e '.["canary-files"].groups == [
"users",
"user-files",
"shared-files-read-write-access",
"paperless-users",
"immich-users",
"jellyfin-users",
"audiobookshelf-users",
"kavita-users",
"mail-archive-users",
"metube-users"
]' >/dev/null <<<"$runtime_canaries"; then
  echo "❌ canary-files must carry all non-admin user-facing access groups."
  echo "   runtimeAccessCanaries: $runtime_canaries"
  exit 1
fi

if jq -e '
to_entries
| map(.value.groups // [])
| flatten
| any(. == "app-admin" or . == "domain_admins" or . == "system_admins" or . == "idm_admins" or test("(^|[-_])admins?($|[-_])"))
' >/dev/null <<<"$runtime_canaries"; then
  echo "❌ Runtime canaries must never be granted admin groups."
  echo "   runtimeAccessCanaries: $runtime_canaries"
  exit 1
fi

age_secret_names="$(snapshot_query '.config.apps.ageSecretNames')"
if jq -e 'index("glancesOauth2ProxyClientSecret") != null or index("glancesOauth2ProxyCookieSecret") != null' >/dev/null <<<"$age_secret_names"; then
  echo "❌ Glances generated secrets must be removed."
  echo "   age secrets: $age_secret_names"
  exit 1
fi
if ! jq -e 'index("runtimeCanaryFilesPassword") != null' >/dev/null <<<"$age_secret_names"; then
  echo "❌ Missing runtime canary agenix secret definition: runtimeCanaryFilesPassword."
  echo "   age secrets: $age_secret_names"
  exit 1
fi

assert_json_true '.config.apps.hasVaultwardenService' \
  "Vaultwarden must remain defined as a systemd service."

require_match scripts/helpers/runtime-health-common.sh 'filebrowser-quantum\.service' \
  "Runtime health inventory must require the FileBrowser Quantum service."
require_match scripts/helpers/runtime-health-common.sh 'https://\$\{vars\.uploadsDomain\}/' \
  "Runtime health inventory must probe the Copyparty uploader edge hostname."
require_match scripts/helpers/runtime-health-common.sh 'https://\$\{vars\.filebrowserDomain\}/' \
  "Runtime health inventory must probe the FileBrowser Quantum edge hostname."
require_match scripts/helpers/runtime-health-common.sh 'vaultwarden\.service' \
  "Runtime health inventory must require the Vaultwarden service."
require_match scripts/helpers/runtime-health-common.sh 'https://\$\{vars\.vaultwardenDomain\}/' \
  "Runtime health inventory must probe the Vaultwarden edge hostname."
require_match scripts/helpers/runtime-health-common.sh 'http://127\.0\.0\.1:8222/' \
  "Runtime health inventory must probe the Vaultwarden local upstream."

jellyfin_library_sync_after="$(snapshot_query '.config.apps.jellyfinLibrarySyncAfter')"
if ! jq -e '
  index("jellyfin-library-bootstrap-v1.service") != null and
  index("jellyfin-library-monitor-v1.service") != null and
  index("jellyfin-storage-layout-v1.service") != null and
  index("data-pool-layout.service") != null
' >/dev/null <<<"$jellyfin_library_sync_after"; then
  echo "❌ Jellyfin library sync must run after the Jellyfin bootstrap, monitor convergence, and storage layout services."
  echo "   after: $jellyfin_library_sync_after"
  exit 1
fi

jellyfin_library_sync_wants="$(snapshot_query '.config.apps.jellyfinLibrarySyncWants')"
if ! jq -e '
  index("jellyfin-library-bootstrap-v1.service") != null and
  index("jellyfin-library-monitor-v1.service") != null and
  index("jellyfin-storage-layout-v1.service") != null and
  index("data-pool-layout.service") != null
' >/dev/null <<<"$jellyfin_library_sync_wants"; then
  echo "❌ Jellyfin library sync must want the Jellyfin bootstrap, monitor convergence, and storage layout services."
  echo "   wants: $jellyfin_library_sync_wants"
  exit 1
fi

jellyfin_library_watch_after="$(snapshot_query '.config.apps.jellyfinLibraryWatchAfter')"
if ! jq -e '
  index("jellyfin.service") != null and
  index("jellyfin-library-bootstrap-v1.service") != null and
  index("jellyfin-library-monitor-v1.service") != null and
  index("jellyfin-storage-layout-v1.service") != null and
  index("data-pool-layout.service") != null
' >/dev/null <<<"$jellyfin_library_watch_after"; then
  echo "❌ Jellyfin library watcher must run after Jellyfin readiness and storage layout services."
  echo "   after: $jellyfin_library_watch_after"
  exit 1
fi

jellyfin_library_watch_wants="$(snapshot_query '.config.apps.jellyfinLibraryWatchWants')"
if ! jq -e '
  index("jellyfin.service") != null and
  index("jellyfin-library-bootstrap-v1.service") != null and
  index("jellyfin-library-monitor-v1.service") != null and
  index("jellyfin-storage-layout-v1.service") != null and
  index("data-pool-layout.service") != null
' >/dev/null <<<"$jellyfin_library_watch_wants"; then
  echo "❌ Jellyfin library watcher must want Jellyfin readiness and storage layout services."
  echo "   wants: $jellyfin_library_watch_wants"
  exit 1
fi

echo "✅ Core config tests passed."
