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
        caddyHostCount = builtins.length (builtins.attrNames cfg.services.caddy.virtualHosts);
        cloudflaredIngressCount = builtins.length (builtins.attrNames cfg.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress);
        oauthSystemNames = builtins.attrNames cfg.services.kanidm.provision.systems.oauth2;
        mailArchiveUiEnable = cfg.services.mail-archive-ui.enable;
        hasCopypartyService = cfg.systemd.services ? "copyparty";
        hasImmichServerService = cfg.systemd.services ? "immich-server";
        hasPaperlessWebService = cfg.systemd.services ? "paperless-web";
        hasOauth2ProxyService = cfg.systemd.services ? "oauth2-proxy";
        hasAudiobookshelfLibrarySync = cfg.systemd.services ? "audiobookshelf-library-sync";
        hasAudiobookshelfLibraryWatch = cfg.systemd.services ? "audiobookshelf-library-watch";
        hasKavitaLibrarySync = cfg.systemd.services ? "kavita-library-sync";
        hasKavitaLibraryWatch = cfg.systemd.services ? "kavita-library-watch";
        hasKiwixLibraryWatch = cfg.systemd.services ? "kiwix-library-watch";
        hasLegacyKiwixLibraryTimer = cfg.systemd.timers ? "kiwix-library-sync";
        hasJellyfinLibraryMonitor = cfg.systemd.services ? "jellyfin-library-monitor-v1";
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
assert_json_true '.config.apps.hasImmichServerService' "Immich service wiring must remain present."
assert_json_true '.config.apps.hasPaperlessWebService' "Paperless service wiring must remain present."
assert_json_true '.config.apps.hasOauth2ProxyService' "OAuth2 Proxy service wiring must remain present."
assert_json_true '.config.apps.hasAudiobookshelfLibrarySync' "Audiobookshelf settled scan service must remain present."
assert_json_true '.config.apps.hasAudiobookshelfLibraryWatch' "Audiobookshelf watcher service must remain present."
assert_json_true '.config.apps.hasKavitaLibrarySync' "Kavita settled scan service must remain present."
assert_json_true '.config.apps.hasKavitaLibraryWatch' "Kavita watcher service must remain present."
assert_json_true '.config.apps.hasKiwixLibraryWatch' "Kiwix watcher service must remain present."
assert_json_true '.config.apps.hasJellyfinLibraryMonitor' "Jellyfin library monitor config service must remain present."
assert_json_false '.config.apps.hasLegacyKiwixLibraryTimer' "Legacy Kiwix polling timer must remain absent."

if [[ "$(snapshot_query '.config.apps.caddyHostCount')" == "0" ]]; then
  echo "❌ Caddy must expose at least one virtual host."
  exit 1
fi

if [[ "$(snapshot_query '.config.apps.cloudflaredIngressCount')" == "0" ]]; then
  echo "❌ Cloudflared must expose at least one ingress entry."
  exit 1
fi

oauth_systems="$(snapshot_query '.config.apps.oauthSystemNames')"
if ! jq -e 'index("oauth2-proxy") != null and index("immich-web") != null and index("paperless-web") != null and index("abs-web") != null' >/dev/null <<<"$oauth_systems"; then
  echo "❌ Expected OIDC-facing application registrations are missing from Kanidm provisioning."
  echo "   OAuth systems: $oauth_systems"
  exit 1
fi

echo "✅ Core config tests passed."
