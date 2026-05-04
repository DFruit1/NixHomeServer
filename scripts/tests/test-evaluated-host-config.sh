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
    -h|--help)
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
      netIface = vars.netIface;
      photosDomain = vars.photosDomain;
      sharePhotosDomain = vars.sharePhotosDomain;
      uploadsDomain = vars.uploadsDomain;
      filebrowserDomain = vars.filebrowserDomain;
      monitorDomain = vars.monitorDomain;
      trafficDomain = vars.trafficDomain;
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
        hasLegacyStorageHealthService = cfg.systemd.services ? "storage-health-report";
        hasLegacyRuntimeHealthService = cfg.systemd.services ? "runtime-health-report";
        hasLegacyStorageHealthTimer = cfg.systemd.timers ? "storage-health-report";
        hasLegacyRuntimeHealthTimer = cfg.systemd.timers ? "runtime-health-report";
        hasLegacyStorageSmartShortInstance = cfg.systemd.timers ? "storage-smart-short@disk1";
        hasLegacyStorageSmartLongInstance = cfg.systemd.timers ? "storage-smart-long@disk1";
      };
      storage = {
        zfsImportScript = cfg.systemd.services.zfs-import-data.script;
      };
      legacy = {
        hasMediaRootRetirementService = cfg.systemd.services ? "media-root-retirement-v1";
        hasRetiredRootsCleanupService = cfg.systemd.services ? "retired-content-roots-cleanup-v1";
      };
      apps = {
        caddyHostNames = builtins.attrNames cfg.services.caddy.virtualHosts;
        caddyHostCount = builtins.length (builtins.attrNames cfg.services.caddy.virtualHosts);
        cloudflaredIngressHostNames = builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
        cloudflaredIngressCount = builtins.length (builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress);
        oauthSystemNames = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2;
        mailArchiveUiEnable = cfg.services.mail-archive-ui.enable;
        hasCopypartyService = cfg.systemd.services ? "copyparty";
        hasFilebrowserQuantumService = cfg.systemd.services ? "filebrowser-quantum";
        hasFilebrowserQuantumAccessSync = cfg.systemd.services ? "filebrowser-quantum-access-sync-v1";
        copypartyGlobalExtraConfig = cfg.services.copyparty.globalExtraConfig;
        copypartyRuntimeConfigSyncScript = cfg.systemd.services.copyparty-runtime-config-sync.script;
        hasImmichServerService = cfg.systemd.services ? "immich-server";
        hasPaperlessWebService = cfg.systemd.services ? "paperless-web";
        hasOauth2ProxyService = cfg.systemd.services ? "oauth2-proxy";
        hasAudiobookshelfLibrarySync = cfg.systemd.services ? "audiobookshelf-library-sync";
        hasAudiobookshelfLibrarySyncTimer = cfg.systemd.timers ? "audiobookshelf-library-sync";
        hasAudiobookshelfLibraryWatch = cfg.systemd.services ? "audiobookshelf-library-watch";
        hasKavitaLibrarySync = cfg.systemd.services ? "kavita-library-sync";
        hasKavitaLibrarySyncTimer = cfg.systemd.timers ? "kavita-library-sync";
        hasKavitaMediaAclSync = cfg.systemd.services ? "kavita-media-acl-sync-v1";
        kavitaLibrarySyncAfter = cfg.systemd.services.kavita-library-sync.after;
        kavitaLibrarySyncWants = cfg.systemd.services.kavita-library-sync.wants;
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
        hasGoaccessReportService = cfg.systemd.services ? "goaccess-report";
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
assert_json_false '.config.monitoring.hasLegacyStorageHealthService' "Legacy storage health reporting service must be absent."
assert_json_false '.config.monitoring.hasLegacyRuntimeHealthService' "Legacy runtime health reporting service must be absent."
assert_json_false '.config.monitoring.hasLegacyStorageHealthTimer' "Legacy storage health reporting timer must be absent."
assert_json_false '.config.monitoring.hasLegacyRuntimeHealthTimer' "Legacy runtime health reporting timer must be absent."
assert_json_false '.config.monitoring.hasLegacyStorageSmartShortInstance' "Legacy per-disk SMART short timers must be absent."
assert_json_false '.config.monitoring.hasLegacyStorageSmartLongInstance' "Legacy per-disk SMART long timers must be absent."
assert_json_false '.config.legacy.hasMediaRootRetirementService' "Legacy media retirement units must be absent."
assert_json_false '.config.legacy.hasRetiredRootsCleanupService' "Legacy retired-root cleanup units must be absent."

require_match <(printf '%s\n' "$(snapshot_query '.config.storage.zfsImportScript' | jq -r '.')") '-d /dev/disk/by-id' \
  "The ZFS import helper must scan the by-id directory generically."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.storage.zfsImportScript' | jq -r '.')") 'ata-HGST_HUS726T4TALA6L4' \
  "The ZFS import helper must not bake in stale pool-member disk IDs."

require_json_equal "$(snapshot_query '.config.apps.mailArchiveUiEnable')" "true" \
  "Mail archive UI must remain enabled."
assert_json_true '.config.apps.hasCopypartyService' "Copyparty service wiring must remain present."
assert_json_true '.config.apps.hasFilebrowserQuantumService' "FileBrowser Quantum service wiring must remain present."
assert_json_true '.config.apps.hasFilebrowserQuantumAccessSync' "FileBrowser Quantum access convergence must remain present."
assert_json_true '.config.apps.hasImmichServerService' "Immich service wiring must remain present."
assert_json_true '.config.apps.hasPaperlessWebService' "Paperless service wiring must remain present."
assert_json_true '.config.apps.hasOauth2ProxyService' "OAuth2 Proxy service wiring must remain present."
assert_json_true '.config.apps.hasAudiobookshelfLibrarySync' "Audiobookshelf settled scan service must remain present."
assert_json_true '.config.apps.hasAudiobookshelfLibrarySyncTimer' "Audiobookshelf overnight scan timer must remain present."
assert_json_false '.config.apps.hasAudiobookshelfLibraryWatch' "Audiobookshelf recursive watcher service must remain absent."
assert_json_true '.config.apps.hasKavitaLibrarySync' "Kavita settled scan service must remain present."
assert_json_true '.config.apps.hasKavitaLibrarySyncTimer' "Kavita overnight scan timer must remain present."
assert_json_true '.config.apps.hasKavitaMediaAclSync' "Kavita media ACL convergence service must remain present."
assert_json_false '.config.apps.hasKavitaLibraryWatch' "Kavita recursive watcher service must remain absent."
assert_json_true '.config.apps.hasKiwixLibraryWatch' "Kiwix watcher service must remain present."
assert_json_true '.config.apps.hasJellyfinLibraryMonitor' "Jellyfin library monitor config service must remain present."
assert_json_true '.config.apps.hasJellyfinLibrarySync' "Jellyfin settled scan service must remain present."
assert_json_false '.config.apps.hasJellyfinLibraryWatch' "Jellyfin recursive watcher service must remain absent."
assert_json_true '.config.apps.hasGlancesService' "Glances service wiring must remain present."
assert_json_true '.config.apps.hasGlancesOauth2ProxyService' "Glances OAuth2 Proxy wiring must remain present."
assert_json_true '.config.apps.hasGoaccessReportService' "GoAccess report service wiring must remain present."
assert_json_false '.config.apps.hasLegacyKiwixLibraryTimer' "Legacy Kiwix polling timer must remain absent."

require_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyGlobalExtraConfig' | jq -r '.')") '\[/upload/\$\{u\}\]' \
  "Copyparty must expose only the upload placeholder volume."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyGlobalExtraConfig' | jq -r '.')") '\[/shared/' \
  "Copyparty must retire shared browsing volumes."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyGlobalExtraConfig' | jq -r '.')") '\[/books/' \
  "Copyparty must retire book browsing volumes."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyRuntimeConfigSyncScript' | jq -r '.')") '\[/upload/\$\{u\}\]' \
  "Copyparty runtime config sync must emit the upload placeholder volume."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyRuntimeConfigSyncScript' | jq -r '.')") '/\$username/files' \
  "Copyparty runtime config sync must retire legacy per-user file volumes."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyRuntimeConfigSyncScript' | jq -r '.')") '/\$username/audiobooks' \
  "Copyparty runtime config sync must retire legacy per-user audiobook volumes."
forbid_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyRuntimeConfigSyncScript' | jq -r '.')") '/\$username/emails' \
  "Copyparty runtime config sync must retire legacy per-user email volumes."
require_match <(printf '%s\n' "$(snapshot_query '.config.apps.copypartyRuntimeConfigSyncScript' | jq -r '.')") 'copyparty -c .+ --exit cfg' \
  "Copyparty runtime config sync must validate the rendered config before startup."

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

if ! jq -e --arg monitor_host "$(snapshot_query '.vars.monitorDomain' | jq -r '.')" 'index($monitor_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must expose the private Glances hostname."
  echo "   hosts: $caddy_host_names"
  exit 1
fi

if ! jq -e --arg traffic_host "$(snapshot_query '.vars.trafficDomain' | jq -r '.')" 'index($traffic_host) != null' >/dev/null <<<"$caddy_host_names"; then
  echo "❌ Caddy must expose the private GoAccess hostname."
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

if jq -e --arg monitor_host "$(snapshot_query '.vars.monitorDomain' | jq -r '.')" 'index($monitor_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must not publish the private Glances hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

if jq -e --arg traffic_host "$(snapshot_query '.vars.trafficDomain' | jq -r '.')" 'index($traffic_host) != null' >/dev/null <<<"$cloudflared_ingress_host_names"; then
  echo "❌ Cloudflared must not publish the private GoAccess hostname."
  echo "   ingress hosts: $cloudflared_ingress_host_names"
  exit 1
fi

oauth_systems="$(snapshot_query '.config.apps.oauthSystemNames')"
if ! jq -e 'index("oauth2-proxy") != null and index("filebrowser-quantum-web") != null and index("immich-web") != null and index("paperless-web") != null and index("abs-web") != null and index("glances-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Expected OIDC-facing application registrations are missing from Kanidm provisioning."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi

if jq -e 'map(.dir) | index("other") != null' >/dev/null <<<"$(snapshot_query '.vars.personalKavitaLibraries')"; then
  echo "❌ Managed personal Kavita libraries must not include the retired other category."
  exit 1
fi

if jq -e 'index("other") != null' >/dev/null <<<"$(snapshot_query '.vars.sharedBooksSubdirs')"; then
  echo "❌ Managed shared book subdirectories must not include the retired other category."
  exit 1
fi

require_match scripts/helpers/runtime-health-common.sh 'filebrowser-quantum\.service' \
  "Runtime health inventory must require the FileBrowser Quantum service."
require_match scripts/helpers/runtime-health-common.sh 'https://\$\{vars\.uploadsDomain\}/' \
  "Runtime health inventory must probe the Copyparty uploader edge hostname."
require_match scripts/helpers/runtime-health-common.sh 'https://\$\{vars\.filebrowserDomain\}/' \
  "Runtime health inventory must probe the FileBrowser Quantum edge hostname."

kavita_library_sync_after="$(snapshot_query '.config.apps.kavitaLibrarySyncAfter')"
if ! jq -e 'index("kavita-media-acl-sync-v1.service") != null' >/dev/null <<<"$kavita_library_sync_after"; then
  echo "❌ Kavita library sync must run after the Kavita media ACL convergence service."
  echo "   after: $kavita_library_sync_after"
  exit 1
fi

kavita_library_sync_wants="$(snapshot_query '.config.apps.kavitaLibrarySyncWants')"
if ! jq -e 'index("kavita-media-acl-sync-v1.service") != null' >/dev/null <<<"$kavita_library_sync_wants"; then
  echo "❌ Kavita library sync must want the Kavita media ACL convergence service."
  echo "   wants: $kavita_library_sync_wants"
  exit 1
fi

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
