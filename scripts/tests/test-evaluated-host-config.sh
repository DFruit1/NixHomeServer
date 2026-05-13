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
monitorDomain = vars.monitorDomain;
runtimeAccessCanaries = vars.runtimeAccessCanaries;
personalKavitaLibraries = vars.personalKavitaLibraries;
sharedBooksSubdirs = vars.sharedBooksSubdirs;
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
fileSystems = {
hasDataMount = cfg.fileSystems ? "/mnt/data";
dataFsType = if cfg.fileSystems ? "/mnt/data" then cfg.fileSystems."/mnt/data".fsType else null;
persistNeededForBoot = cfg.fileSystems."/persist".neededForBoot;
nixNeededForBoot = cfg.fileSystems."/nix".neededForBoot;
hasLegacyWorkspacesMount = cfg.fileSystems ? "/mnt/data/workspaces";
hasLegacyMailArchiveMount = cfg.fileSystems ? "/mnt/data/mail-archive";
};
restic = {
repository = cfg.services.restic.backups.system-state.repository;
pathCount = builtins.length cfg.services.restic.backups.system-state.paths;
};
monitoring = {
hasSystemHealthService = cfg.systemd.services ? "system-health-report";
hasSystemHealthTimer = cfg.systemd.timers ? "system-health-report";
hasStorageSmartShortService = cfg.systemd.services ? "storage-smart-short";
hasStorageSmartLongService = cfg.systemd.services ? "storage-smart-long";
hasStorageSmartShortTimer = cfg.systemd.timers ? "storage-smart-short";
hasStorageSmartLongTimer = cfg.systemd.timers ? "storage-smart-long";
hasSmartdService = cfg.systemd.services ? "smartd";
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
mailArchiveUiReadWritePaths =
cfg.systemd.services."mail-archive-ui".serviceConfig.ReadWritePaths or [ ];
mailArchiveUiPath =
map (package: lib.getName package) (cfg.systemd.services."mail-archive-ui".path or [ ]);
mailArchiveSyncPath =
map (package: lib.getName package) (cfg.systemd.services."mail-archive-sync".path or [ ]);
hasCopypartyService = cfg.systemd.services ? "copyparty";
hasCopypartyRuntimeConfigSync = cfg.systemd.services ? "copyparty-runtime-config-sync";
copypartyServiceSupplementaryGroups =
cfg.systemd.services.copyparty.serviceConfig.SupplementaryGroups or [ ];
copypartyServiceBindPaths =
cfg.systemd.services.copyparty.serviceConfig.BindPaths or [ ];
hasFilebrowserQuantumService = cfg.systemd.services ? "filebrowser-quantum";
hasFilebrowserQuantumAccessSync = cfg.systemd.services ? "filebrowser-quantum-access-sync-v1";
filebrowserQuantumExtraGroups = cfg.users.users.filebrowser-quantum.extraGroups or [ ];
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
hasJellyfinLibrarySync = cfg.systemd.services ? "jellyfin-library-sync";
jellyfinLibrarySyncAfter = cfg.systemd.services.jellyfin-library-sync.after;
jellyfinLibrarySyncWants = cfg.systemd.services.jellyfin-library-sync.wants;
hasJellyfinLibraryWatch = cfg.systemd.services ? "jellyfin-library-watch";
hasGlancesService = cfg.systemd.services ? "glances";
hasGlancesOauth2ProxyService = cfg.systemd.services ? "glances-oauth2-proxy";
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
assert_json_false '.config.fileSystems.hasLegacyWorkspacesMount' "Legacy workspaces mounts must remain removed."
assert_json_false '.config.fileSystems.hasLegacyMailArchiveMount' "Legacy mail-archive mounts must remain removed."

require_json_equal "$(snapshot_query '.config.restic.repository')" '"/mnt/backup-system-state/restic/system-state"' \
  "System-state Restic backups must remain configured."
if [[ "$(snapshot_query '.config.restic.pathCount')" == "0" ]]; then
  echo "❌ System-state Restic backups must include at least one path."
  exit 1
fi

assert_json_true '.config.monitoring.hasSystemHealthService' "System health reporting service must remain defined."
assert_json_true '.config.monitoring.hasSystemHealthTimer' "System health reporting timer must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartShortService' "SMART short sweep service must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartLongService' "SMART long sweep service must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartShortTimer' "SMART short sweep timer must remain defined."
assert_json_true '.config.monitoring.hasStorageSmartLongTimer' "SMART long sweep timer must remain defined."
assert_json_true '.config.monitoring.hasSmartdService' "smartd must remain defined."

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
require_match modules/Core_Modules/storage/fileshare-user-roots.nix 'apply_noaccess_acl filebrowser-quantum "\$root/emails/\.internal-sync"' \
  "FileBrowser Quantum must not be able to traverse the hidden internal email sync tree."
forbid_match modules/audiobookshelf/storage.nix 'audiobookshelf-user-storage-acl-sync-v1' \
  "Audiobookshelf per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/filebrowser-quantum/storage.nix 'filebrowser-quantum-user-storage-acl-sync-v1' \
  "FileBrowser Quantum per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/immich/storage.nix 'immich-user-storage-acl-sync-v1' \
  "Immich per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/kavita/storage.nix 'kavita-media-acl-sync-v1' \
  "Kavita per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/mail-archive-ui/storage.nix 'mail-archive-ui-user-storage-acl-sync-v1' \
  "Mail Archive UI per-user ACL convergence must stay centralized in fileshare-user-root-sync."
forbid_match modules/paperless/storage.nix 'paperless-user-storage-acl-sync-v1' \
  "Paperless per-user ACL convergence must stay centralized in fileshare-user-root-sync."
require_match scripts/helpers/runtime-health-common.sh 'allowedGroups = \[ "user-files" "shared-files-read-write-access" \];' \
  "Runtime health inventory must keep FileBrowser access scoped to file access groups only."
forbid_match modules/filebrowser-quantum/default.nix 'ensure_group_membership "mail-archive-users"' \
  "FileBrowser access convergence must not grant access from mail-archive-users alone."
forbid_match configuration.nix './modules/mail-archive-paperless' \
  "Mail Archive UI must not import the retired Paperless handoff module."

mail_archive_ui_environment="$(snapshot_query '.config.apps.mailArchiveUiEnvironment')"
if jq -e 'has("MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT") or has("MAIL_ARCHIVE_UI_PAPERLESS_STAGING_DIR")' >/dev/null <<<"$mail_archive_ui_environment"; then
  echo "❌ Mail Archive UI environment must not expose Paperless consume/staging paths."
  echo "   environment: $mail_archive_ui_environment"
  exit 1
fi

mail_archive_ui_read_write_paths="$(snapshot_query '.config.apps.mailArchiveUiReadWritePaths')"
if jq -e 'map(test("mail-archive|paperless") and test("consume|staging")) | any' >/dev/null <<<"$mail_archive_ui_read_write_paths"; then
  echo "❌ Mail Archive UI ReadWritePaths must not include Paperless consume/staging paths."
  echo "   ReadWritePaths: $mail_archive_ui_read_write_paths"
  exit 1
fi

copyparty_service_supplementary_groups="$(snapshot_query '.config.apps.copypartyServiceSupplementaryGroups')"
if ! jq -e 'index("users") != null' >/dev/null <<<"$copyparty_service_supplementary_groups"; then
  echo "❌ Copyparty must declare users as a supplementary runtime group."
  echo "   SupplementaryGroups: $copyparty_service_supplementary_groups"
  exit 1
fi
if jq -e 'index("mail-archive-ui") != null' >/dev/null <<<"$copyparty_service_supplementary_groups"; then
  echo "❌ Copyparty must not keep legacy mail-archive-ui supplementary access."
  echo "   SupplementaryGroups: $copyparty_service_supplementary_groups"
  exit 1
fi

users_group_members="$(snapshot_query '.config.apps.usersGroupMembers')"
if ! jq -e 'index("copyparty") != null' >/dev/null <<<"$users_group_members"; then
  echo "❌ The local users group must keep copyparty as a declarative member."
  echo "   users group members: $users_group_members"
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
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.oauth2ProxyExecStart' | jq -r '.')") "--cookie-expire='336h0m0s'" \
  "Uploads OAuth2 Proxy must keep browser upload sessions valid beyond multi-day transfer estimates."
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
assert_json_true '.config.apps.hasKiwixLibraryWatch' "Kiwix watcher service must remain present."
assert_json_true '.config.apps.hasJellyfinLibraryMonitor' "Jellyfin library monitor config service must remain present."
assert_json_true '.config.apps.hasJellyfinLibrarySync' "Jellyfin settled scan service must remain present."
assert_json_false '.config.apps.hasJellyfinLibraryWatch' "Jellyfin recursive watcher service must remain absent."
assert_json_true '.config.apps.hasGlancesService' "Glances service wiring must remain present."
assert_json_true '.config.apps.hasGlancesOauth2ProxyService' "Glances OAuth2 Proxy wiring must remain present."
assert_json_false '.config.apps.hasLegacyKiwixLibraryTimer' "Legacy Kiwix polling timer must remain absent."

assert_json_false '.config.apps.hasCopypartyRuntimeConfigSync' "Copyparty must use the native module config renderer, not a duplicate runtime config sync service."
copyparty_volumes="$(snapshot_query '.config.apps.copypartyVolumes')"
if ! jq -e '
has("/${u}") and
(.["/${u}"].path | test("/\\$\\{u\\}/uploads$"))
' >/dev/null <<<"$copyparty_volumes"; then
  echo "❌ Copyparty must map each authenticated user to their own upload-root volume."
  echo "   volumes: $copyparty_volumes"
  exit 1
fi
if ! jq -e '.["/${u}"].access.rwmd == "${u}"' >/dev/null <<<"$copyparty_volumes"; then
  echo "❌ Copyparty must grant upload-root access only to the matching authenticated user."
  echo "   volumes: $copyparty_volumes"
  exit 1
fi
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.chmod_d')" '770' \
  "Copyparty should let the setgid upload parent directory apply inherited group ownership."
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.chmod_f')" '660' \
  "Copyparty should keep uploaded files private to owner/group."
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.fk')" '4' \
  "Copyparty must keep filekeys enabled for upload-root files."
require_json_equal "$(snapshot_query '.config.apps.copypartyVolumes["/${u}"].flags.e2d')" 'true' \
  "Copyparty must keep the upload database enabled."
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
forbid_match <(printf '%s\n' "$copyparty_bind_paths") '/shared' \
  "Copyparty must not keep legacy shared-root filesystem exposure."
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

if ! jq -e --arg monitor_host "$(snapshot_query '.vars.monitorDomain' | jq -r '.')" 'index($monitor_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must expose the private Glances hostname."
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

if jq -e --arg monitor_host "$(snapshot_query '.vars.monitorDomain' | jq -r '.')" 'index($monitor_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must not publish the private Glances hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

oauth_systems="$(snapshot_query '.config.apps.oauthSystemNames')"
if ! jq -e 'index("oauth2-proxy") != null and index("filebrowser-quantum-web") != null and index("immich-web") != null and index("paperless-web") != null and index("abs-web") != null and index("glances-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Expected OIDC-facing application registrations are missing from Kanidm provisioning."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi
if jq -e 'index("vaultwarden-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Vaultwarden must not be registered as a Kanidm OAuth2 client."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi

provision_groups="$(snapshot_query '.config.apps.provisionGroupNames')"
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
"audiobookshelf-users",
"kavita-users",
"glances-users",
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
if ! jq -e 'index("jellyfin-library-monitor-v1.service") != null and index("data-pool-layout.service") != null' >/dev/null <<<"$jellyfin_library_sync_after"; then
  echo "❌ Jellyfin library sync must run after the Jellyfin monitor convergence and storage layout services."
  echo "   after: $jellyfin_library_sync_after"
  exit 1
fi

jellyfin_library_sync_wants="$(snapshot_query '.config.apps.jellyfinLibrarySyncWants')"
if ! jq -e 'index("jellyfin-library-monitor-v1.service") != null and index("data-pool-layout.service") != null' >/dev/null <<<"$jellyfin_library_sync_wants"; then
  echo "❌ Jellyfin library sync must want the Jellyfin monitor convergence and storage layout services."
  echo "   wants: $jellyfin_library_sync_wants"
  exit 1
fi

echo "✅ Core config tests passed."
