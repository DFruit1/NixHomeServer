#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg

hostname="$(nix_eval_var 'vars.hostname')"
mail_archive_port="$(nix_eval_config_json 'services.mail-archive-ui.port')"

echo "ℹ️ Checking evaluated core service enablement…"
require_json_equal "$(nix_eval_config_json 'services.caddy.enable')" "true" \
  "Caddy must remain enabled."
require_json_equal "$(nix_eval_config_json 'services.cloudflared.enable')" "true" \
  "Cloudflared must remain enabled."
require_json_equal "$(nix_eval_config_json 'services.unbound.enable')" "true" \
  "Unbound must remain enabled."
require_json_equal "$(nix_eval_config_json 'services.kanidm.enableServer')" "true" \
  "Kanidm server must remain enabled."
require_json_equal "$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.autoStart')" "true" \
  "NetBird client must remain enabled."
require_json_equal "$(nix_eval_config_json 'services.mail-archive-ui.enable')" "true" \
  "Mail archive UI must remain enabled."
system_packages_json="$(nix_eval_config_json 'environment.systemPackages')"
if ! printf '%s\n' "$system_packages_json" | rg 'jq-[^"]*' >/dev/null; then
  echo "❌ The evaluated system path must include jq for runtime validation tooling."
  exit 1
fi

echo "ℹ️ Checking simplified LAN networking…"
require_json_equal "$(nix_eval_config_json 'networking.defaultGateway.address')" "\"$(nix_eval_var 'vars.serverLanGateway')\"" \
  "The primary LAN gateway must come from vars.serverLanGateway."
require_json_equal "$(nix_eval_config_json "networking.interfaces.\"$(nix_eval_var 'vars.netIface')\".useDHCP")" "false" \
  "The primary LAN interface must not use DHCP."
lan_addresses_json="$(nix_eval_config_json "networking.interfaces.\"$(nix_eval_var 'vars.netIface')\".ipv4.addresses")"
require_json_equal "$(printf '%s\n' "$lan_addresses_json" | jq -c '.[0].address')" "\"$(nix_eval_var 'vars.serverLanIP')\"" \
  "The primary LAN interface must keep the configured static IPv4 address."
require_json_equal "$(printf '%s\n' "$lan_addresses_json" | jq -c '.[0].prefixLength')" "$(nix eval --json --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanPrefixLength')" \
  "The primary LAN interface must keep the configured static IPv4 prefix length."
require_json_equal "$(nix_eval_config_json 'networking.nameservers')" '["127.0.0.1"]' \
  "The host must still resolve through the local Unbound instance."
require_json_equal "$(nix_eval_config_json 'networking.networkmanager.enable')" "false" \
  "NetworkManager must remain disabled for the static LAN configuration."
require_json_equal "$(nix_eval_json 'vars.lanDnsDomain')" '"home.arpa"' \
  "vars.lanDnsDomain must keep the reserved LAN-only DNS suffix."
require_json_equal "$(nix_eval_json 'vars.lanDnsHosts.router')" "\"$(nix_eval_var 'vars.serverLanGateway')\"" \
  "The router LAN DNS record must follow vars.serverLanGateway."
require_json_equal "$(nix_eval_json 'vars.kanidmAuthSessionExpirySeconds')" "259200" \
  "Kanidm auth session grace must retain the configured three-day lifetime."

echo "ℹ️ Checking storage topology config values…"
require_json_equal "$(nix_eval_json 'vars.dnsMode')" '"split-horizon"' \
  "vars.dnsMode must switch the host to split-horizon DNS."
require_json_equal "$(nix_eval_json 'vars.zfsDataPool.name')" '"data"' \
  "vars.zfsDataPool must keep the canonical pool name."
require_json_equal "$(nix_eval_json 'builtins.length vars.zfsDataPool.mirrorPairs')" "1" \
  "vars.zfsDataPool must define one active mirror pair."
require_json_equal "$(nix_eval_json 'builtins.length vars.zfsDataPool.datasets')" "3" \
  "vars.zfsDataPool must keep the expected child datasets."
require_json_contains "$(nix_eval_json 'vars.zfsDataPool.datasets')" 'media' \
  "vars.zfsDataPool must keep the media dataset."
require_json_contains "$(nix_eval_json 'vars.zfsDataPool.datasets')" 'workspaces' \
  "vars.zfsDataPool must keep the workspaces backing dataset."
require_json_contains "$(nix_eval_json 'vars.zfsDataPool.datasets')" 'mail-archive' \
  "vars.zfsDataPool must include the dedicated mail-archive dataset."
forbid_json_contains "$(nix_eval_json 'vars.zfsDataPool.datasets')" 'appdata' \
  "vars.zfsDataPool must not retain the removed appdata dataset."
require_json_contains "$(nix_eval_json 'vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V1JAKPNH" \
  "The ZFS data pool must include the healthiest disk."
require_json_contains "$(nix_eval_json 'vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V1J9PKDH" \
  "The ZFS data pool must include the second good disk."
forbid_json_contains "$(nix_eval_json 'vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V6G7R6MS" \
  "The ZFS data pool must leave the oldest healthy disk out as an offline spare."
forbid_json_contains "$(nix_eval_json 'vars.zfsDataPoolDiskIds')" "ata-HGST_HUS726T4TALA6L4_V1G5K8YC" \
  "The ZFS data pool must exclude the faulted disk."
forbid_match vars.nix 'enableBackups|enableBackup[D]isk|backup[D]isk|backupMount[P]oint|backupRe[p]ository' \
  "vars.nix must not retain the removed local-backup settings."
require_json_equal "$(nix_eval_json 'builtins.length vars.coldStoragePools')" "0" \
  "vars.coldStoragePools must be empty when no manual cold-storage pool is attached."
require_json_equal "$(nix_eval_json 'vars.coldStorageMountPoint')" '"/mnt/cold-storage"' \
  "vars.coldStorageMountPoint must keep the reserved optional mountpoint."
require_json_equal "$(nix_eval_json 'builtins.length vars.monitoredStorageDiskIds')" "2" \
  "The monitored storage disk list must include only the active mirror pair."
require_json_equal "$(nix_eval_json 'vars.usersWorkspaceRoot')" '"/mnt/data/users"' \
  "Per-user content roots must resolve directly under the ZFS data pool."
require_json_equal "$(nix_eval_json 'vars.sharedPublicRoot')" '"/mnt/data/shared"' \
  "The shared content root must resolve directly under the ZFS data pool."
require_json_equal "$(nix_eval_json 'vars.sharedAudiobooksRoot')" '"/mnt/data/shared/audiobooks"' \
  "Shared audiobooks must resolve through the shared public upload tree."
require_json_equal "$(nix_eval_json 'vars.sharedEmailsRoot')" '"/mnt/data/shared/emails"' \
  "Shared mail archives must resolve through the shared content root."
require_json_equal "$(nix_eval_json 'vars.sharedEbooksRoot')" '"/mnt/data/shared/books/ebooks"' \
  "Shared ebooks must resolve through the shared public upload tree."
require_json_equal "$(nix_eval_json 'vars.sharedMoviesRoot')" '"/mnt/data/shared/videos/movies"' \
  "Shared movies must resolve through the shared public upload tree."
require_json_contains "$(nix_eval_json 'vars.userBooksSubdirs')" "ebooks" \
  "Per-user book roots must include ebooks."
require_json_contains "$(nix_eval_json 'vars.userBooksSubdirs')" "other" \
  "Per-user book roots must include the fixed other category."
require_json_contains "$(nix_eval_json 'vars.userVideoSubdirs')" "movies" \
  "Per-user video roots must include movies."
require_json_contains "$(nix_eval_json 'vars.userVideoSubdirs')" "music-videos" \
  "Per-user video roots must include music videos."
require_json_contains "$(nix_eval_json 'vars.userVideoSubdirs')" "youtube" \
  "Per-user video roots must include YouTube."
require_json_contains "$(nix_eval_json 'vars.userVideoSubdirs')" "other" \
  "Per-user video roots must include the fixed other category."
forbid_json_contains "$(nix_eval_json 'vars.sharedBooksSubdirs')" "other" \
  "Shared book roots must remain unchanged."
forbid_json_contains "$(nix_eval_json 'vars.sharedVideoSubdirs')" "music-videos" \
  "Shared video roots must not gain personal-only categories."
forbid_json_contains "$(nix_eval_json 'vars.sharedVideoSubdirs')" "youtube" \
  "Shared video roots must remain unchanged."
forbid_json_contains "$(nix_eval_json 'vars.sharedVideoSubdirs')" "other" \
  "Shared video roots must remain unchanged."
require_json_equal "$(nix_eval_config_json 'services.mail-archive-ui.storeRoot')" '"/mnt/data/users"' \
  "Mail archive storage must resolve through the per-user content root."
restic_paths_json="$(nix_eval_config_json 'services.restic.backups.system-state.paths')"
require_json_contains "$restic_paths_json" "/var/lib" \
  "The system-state backup must include /var/lib for SSD-backed app state."
require_json_contains "$restic_paths_json" "/persist/appdata" \
  "The system-state backup must include /persist/appdata for SSD-backed app state."
require_fixed modules/immich/default.nix '"${vars.mediaRoot}/photos/managed"' \
  "Immich must derive its managed library under vars.mediaRoot."
require_fixed modules/Core_Modules/restic-state/default.nix 'app-state-roots.tsv' \
  "The Restic metadata staging must emit an explicit app-state inventory."
require_fixed modules/Core_Modules/restic-state/default.nix '/var/lib/jellyfin' \
  "The Restic app-state inventory must cover Jellyfin."
require_fixed modules/Core_Modules/restic-state/default.nix '/persist/appdata/mail-archive-ui' \
  "The Restic app-state inventory must cover the mail archive UI."
forbid_match vars.nix 'appdataRoot|audiobookshelfDataDir|audiobookshelfConfigDir|audiobookshelfMetadataDir|audiobookshelfBackupDir|jellyfinDataDir|jellyfinLogDir|kavitaDataDir|paperlessDataDir|mailArchiveUiDataDir' \
  "vars.nix must not retain the old shared app-state path definitions."

echo "ℹ️ Checking data-disk stack extraction…"
require_fixed configuration.nix './modules/Core_Modules/storage-monitoring' \
  "configuration.nix must import the storage-monitoring module."
require_fixed configuration.nix './disko-system.nix' \
  "configuration.nix must import the SSD Disko layout separately from the data migration layout."
require_json_equal "$(nix_eval_config_json 'fileSystems."/mnt/data".fsType')" '"zfs"' \
  "The data pool must be mounted at /mnt/data as ZFS."
require_json_equal "$(nix_eval_json 'let flake = builtins.getFlake (toString ./.); hostname = vars.hostname; in flake.nixosConfigurations.${hostname}.config.fileSystems ? "/mnt/data/media"')" "true" \
  "The media dataset mount must exist."
require_json_equal "$(nix_eval_json 'let flake = builtins.getFlake (toString ./.); hostname = vars.hostname; in flake.nixosConfigurations.${hostname}.config.fileSystems ? "/mnt/data/workspaces"')" "true" \
  "The workspaces backing dataset mount must exist."
require_json_equal "$(nix_eval_json 'let flake = builtins.getFlake (toString ./.); hostname = vars.hostname; in flake.nixosConfigurations.${hostname}.config.fileSystems ? "/mnt/data/mail-archive"')" "true" \
  "The mail-archive dataset mount must exist."
require_json_equal "$(nix_eval_config_json 'networking.hostId')" '"84e8c12a"' \
  "networking.hostId must be set for ZFS imports."
require_json_equal "$(nix_eval_config_json 'services.smartd.enable')" "true" \
  "SMART monitoring must remain enabled."
smartd_devices="$(nix_eval_config_json 'services.smartd.devices')"
require_json_equal "$(printf '%s\n' "$smartd_devices" | jq 'length')" "2" \
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
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-health-report".timerConfig.OnCalendar')" '"*:0/30"' \
  "Storage monitoring must generate the 30-minute report timer."
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-smart-short@disk1".timerConfig.OnCalendar')" '"Sat *-*-* 03:00:00"' \
  "disk1 must keep the weekly short SMART schedule."
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-smart-short@disk2".timerConfig.OnCalendar')" '"Sat *-*-* 03:20:00"' \
  "disk2 must keep the weekly short SMART schedule."
require_json_equal "$(nix_eval_json 'let flake = builtins.getFlake (toString ./.); hostname = vars.hostname; in flake.nixosConfigurations.${hostname}.config.systemd.timers ? "storage-smart-short@cold-v1jan8ph"')" "false" \
  "No cold-storage SMART timer should exist when no cold-storage pool is configured."
require_json_equal "$(nix_eval_config_json 'services.zfs.autoScrub.enable')" "true" \
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

echo "ℹ️ Checking active routing surface…"
caddy_hosts="$(nix_eval_config_json 'services.caddy.virtualHosts' | jq 'keys')"
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.kanidmDomain')" \
  "Caddy must serve the Kanidm hostname."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.filesDomain')" \
  "Caddy must serve files.<domain>."
require_json_contains "$caddy_hosts" "$(nix_eval_var 'vars.emailsDomain')" \
  "Caddy must serve emails.<domain>."
forbid_json_contains "$caddy_hosts" "photo.$(nix_eval_var 'vars.domain')" \
  "Caddy must not retain the legacy photo hostname."
forbid_json_contains "$caddy_hosts" "audiobook.$(nix_eval_var 'vars.domain')" \
  "Caddy must not retain the legacy audiobook hostname."
forbid_json_contains "$caddy_hosts" "book.$(nix_eval_var 'vars.domain')" \
  "Caddy must not retain the legacy book hostname."
forbid_json_contains "$caddy_hosts" "video.$(nix_eval_var 'vars.domain')" \
  "Caddy must not retain the legacy video hostname."
if ! rg -F 'privateHostedRecords vars.serverLanIP' modules/Core_Modules/unbound/default.nix >/dev/null; then
  echo "❌ Unbound must still derive split-horizon LAN records from vars.serverLanIP."
  exit 1
fi
unbound_interfaces="$(nix_eval_config_json 'services.unbound.settings.server.interface')"
require_json_contains "$unbound_interfaces" "127.0.0.1" \
  "Unbound must listen on localhost for server-local recursion."
require_json_contains "$unbound_interfaces" "$(nix_eval_var 'vars.nbIP')" \
  "Unbound must listen on the NetBird address."
require_json_contains "$unbound_interfaces" "$(nix_eval_var 'vars.serverLanIP')" \
  "Unbound must listen on the primary LAN address in split-horizon mode."
lan_view_json="$(nix_eval_config_json 'services.unbound.settings.view')"
lan_view_local_zones="$(printf '%s\n' "$lan_view_json" | jq -r '.[] | select(.name == "lan") | .["local-zone"] | join("\n")')"
lan_view_local_data="$(printf '%s\n' "$lan_view_json" | jq -r '.[] | select(.name == "lan") | .["local-data"] | join("\n")')"
require_json_contains "$(jq -Rs . <<<"$lan_view_local_zones")" "$(nix_eval_var 'vars.lanDnsDomain') static" \
  "The LAN Unbound view must serve the LAN-only DNS zone."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "$(nix_eval_var 'vars.hostname').$(nix_eval_var 'vars.lanDnsDomain')" \
  "The LAN Unbound view must publish the server LAN hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" "router.$(nix_eval_var 'vars.lanDnsDomain')" \
  "The LAN Unbound view must publish the router LAN hostname."
require_json_contains "$(jq -Rs . <<<"$lan_view_local_data")" 'PTR' \
  "The LAN Unbound view must include reverse DNS records for LAN hosts."
lan_prefix_length="$(nix_eval_var 'toString vars.serverLanPrefixLength')"
samba_settings_json="$(nix_eval_config_json 'services.samba.settings')"
samba_settings_keys="$(nix_eval_json 'let flake = builtins.getFlake (toString ./.); hostname = vars.hostname; in builtins.attrNames flake.nixosConfigurations.${hostname}.config.services.samba.settings')"
samba_interfaces="$(printf '%s\n' "$samba_settings_json" | jq -c '.global.interfaces')"
require_json_equal "$samba_interfaces" "\"lo $(nix_eval_var 'vars.netIface')\"" \
  "Samba must bind only to localhost and the primary LAN interface."
require_json_equal "$(printf '%s\n' "$samba_settings_json" | jq -c '.global["hosts allow"]')" "\"$(nix_eval_var 'vars.serverLanIP')/${lan_prefix_length} 127.0.0.1\"" \
  "Samba hosts-allow rules must be restricted to the LAN prefix plus localhost."
require_json_equal "$(printf '%s\n' "$samba_settings_json" | jq -c '.data.path')" "\"$(nix_eval_var 'vars.dataRoot')\"" \
  "The admin SMB share must expose the full data root."
require_json_equal "$(printf '%s\n' "$samba_settings_json" | jq -c '.data["valid users"]')" "\"$(nix_eval_var 'vars.kanidmAdminUser')\"" \
  "The admin SMB share must be gated to the delegated admin user."
require_json_equal "$(printf '%s\n' "$samba_settings_json" | jq -c '.data["admin users"]')" "\"$(nix_eval_var 'vars.kanidmAdminUser')\"" \
  "The admin SMB share must grant admin semantics to the delegated admin user."
require_json_contains "$(nix_eval_config_json "networking.firewall.interfaces.\"$(nix_eval_var 'vars.netIface')\".allowedTCPPorts")" "139" \
  "The LAN interface must allow SMB port 139."
require_json_contains "$(nix_eval_config_json "networking.firewall.interfaces.\"$(nix_eval_var 'vars.netIface')\".allowedTCPPorts")" "445" \
  "The LAN interface must allow SMB port 445."
netbird_iface="$(nix_eval_config_json 'services.netbird.clients.myNetbirdClient.interface' | jq -r .)"
forbid_json_contains "$(nix_eval_config_json "networking.firewall.interfaces.\"${netbird_iface}\".allowedTCPPorts")" "139" \
  "The NetBird interface must not allow SMB port 139."
forbid_json_contains "$(nix_eval_config_json "networking.firewall.interfaces.\"${netbird_iface}\".allowedTCPPorts")" "445" \
  "The NetBird interface must not allow SMB port 445."
forbid_json_contains "$samba_settings_keys" "homes" \
  "Samba must not retain the old homes share."
forbid_json_contains "$samba_settings_keys" "exchange" \
  "Samba must not retain the old exchange share."
forbid_json_contains "$samba_settings_keys" "public" \
  "Samba must not retain the old public share."
forbid_json_contains "$samba_settings_keys" "photos-upload" \
  "Samba must not retain the old photos-upload share."
forbid_json_contains "$samba_settings_keys" "documents-upload" \
  "Samba must not retain the old documents-upload share."
require_match modules/Core_Modules/caddy/default.nix '@copyparty_shares path /shares /shares/\*' \
  "Caddy must bypass oauth2-proxy only for the explicit Copyparty share namespace."
require_match modules/copyparty/default.nix 'shr = "/shares";' \
  "Copyparty must publish anonymous share links under /shares."
require_match modules/copyparty/default.nix '"shr-who" = "auth";' \
  "Copyparty share creation must be limited to authenticated users."
require_match modules/copyparty/default.nix 'rwmda: @acct' \
  "Writable shared volumes must require authenticated Copyparty accounts."
require_match modules/copyparty/default.nix "\\$\\{vars\\.usersWorkspaceRoot\\}/''\\$\\{u\\}" \
  "Copyparty per-user roots must point at each user's top-level content directory."
require_fixed modules/copyparty/default.nix '${vars.sharedPublicRoot}' \
  "Copyparty /shared must point at the shared content root."
forbid_match modules/copyparty/default.nix 'media-library' \
  "Copyparty must not retain the removed broad media-library group."
require_json_contains "$(nix_eval_json 'vars.userContentSubdirs')" "emails" \
  "Per-user content roots must include an emails directory."
require_json_contains "$(nix_eval_json 'vars.sharedContentSubdirs')" "emails" \
  "Shared content roots must include an emails directory."
require_match modules/copyparty/default.nix '\[/shared/documents\]' \
  "Copyparty must keep exposing Paperless archives through /shared/documents."
require_match modules/copyparty/default.nix '\[/shared/emails\]' \
  "Copyparty must expose shared mail archives as a read-only subtree."
require_match modules/copyparty/default.nix "\\[/''\\$\\{u\\}/emails\\]" \
  "Copyparty must expose each user's mail archive as a read-only subtree."
forbid_match modules/copyparty/default.nix '\[/documents\]' \
  "Copyparty must not expose the old global documents mount."
forbid_match modules/copyparty/default.nix '\[/audiobooks\]' \
  "Copyparty must not expose the old global audiobooks mount."
forbid_match modules/copyparty/default.nix '\[/books\]' \
  "Copyparty must not expose the old global books mount."
forbid_match modules/copyparty/default.nix '\[/videos\]' \
  "Copyparty must not expose the old global videos mount."
forbid_match modules/copyparty/default.nix '\[/shared/public\]' \
  "Copyparty must not retain the public subdirectory."
forbid_match modules/copyparty/default.nix '\[/shared/exchange\]' \
  "Copyparty must not retain the exchange subdirectory."
forbid_match modules/copyparty/default.nix '\[/shared/photos\]' \
  "Copyparty must not retain the photos subdirectory."

echo "ℹ️ Checking cold-storage tooling…"
require_fixed modules/Core_Modules/storage/layout.nix 'coldStorageMountPoint' \
  "Storage tmpfiles must create the cold-storage mountpoint."
require_fixed scripts/cold-storage.sh 'Usage: scripts/cold-storage.sh <status|mount|unmount> [pool-name]' \
  "The cold-storage helper must expose named status, mount, and unmount commands."
require_fixed scripts/cold-storage.sh 'vars.coldStoragePools' \
  "The cold-storage helper must resolve pools from vars.nix."
require_fixed scripts/cold-storage.sh 'zpool import -N -d /dev/disk/by-id' \
  "The cold-storage helper must import pools without auto-mounting them."

echo "ℹ️ Checking power and mail-archive essentials…"
forbid_match configuration.nix './modules/[b]ackup' \
  "configuration.nix must not import the removed local-backup module."
require_fixed scripts/check-repo.sh 'nix build ".#checks.${system}.mail-archive-ui-test" --print-build-logs' \
  "Repository checks must execute the built mail archive UI test derivation."
require_json_equal "$(nix_eval_config_json 'powerManagement.cpuFreqGovernor')" '"powersave"' \
  "Power management must retain the powersave governor."
require_json_equal "$(nix_eval_config_json 'systemd.timers.power-management-nightly-suspend.timerConfig.OnCalendar')" '"*-*-* 23:30:00"' \
  "Nightly suspend must keep the current schedule."
require_json_equal "$mail_archive_port" "9011" \
  "Mail archive UI must keep the expected local port."
require_json_equal "$(nix_eval_config_json 'services.mail-archive-ui.dataDir')" '"/persist/appdata/mail-archive-ui"' \
  "Mail archive UI state must live on the SSD-backed persist volume."
require_json_equal "$(nix_eval_config_json 'services.paperless.dataDir')" '"/var/lib/paperless"' \
  "Paperless state must live under /var/lib."
require_json_equal "$(nix_eval_config_json 'services.kavita.dataDir')" '"/var/lib/kavita"' \
  "Kavita state must live under /var/lib."
require_json_equal "$(nix_eval_config_json 'services.jellyfin.dataDir')" '"/var/lib/jellyfin"' \
  "Jellyfin state must live under /var/lib."
require_json_equal "$(nix_eval_config_json 'users.users.audiobookshelf.extraGroups')" '["audiobookshelf-media"]' \
  "Audiobookshelf must use the app-specific media group."
require_json_equal "$(nix_eval_config_json 'users.users.kavita.extraGroups')" '["kavita-media"]' \
  "Kavita must use the app-specific media group."
require_json_equal "$(nix_eval_config_json 'users.users.jellyfin.extraGroups')" '["jellyfin-media"]' \
  "Jellyfin must use the app-specific media group."
forbid_match modules/audiobookshelf/service.nix 'media-library' \
  "Audiobookshelf must not retain the removed broad media-library group."
forbid_match modules/kavita/default.nix 'media-library' \
  "Kavita must not retain the removed broad media-library group."
forbid_match modules/jellyfin/service.nix 'media-library' \
  "Jellyfin must not retain the removed broad media-library group."
require_json_equal "$(nix_eval_config_json 'systemd.timers.audiobookshelf-library-sync-v1.timerConfig.OnCalendar')" '"*-*-* *:*:00"' \
  "Audiobookshelf library sync must run every minute."
require_json_equal "$(nix_eval_config_json 'systemd.timers.kavita-library-sync-v1.timerConfig.OnCalendar')" '"*-*-* *:*:00"' \
  "Kavita library sync must run every minute."
require_json_equal "$(nix_eval_config_json 'systemd.timers.jellyfin-user-sync-v1.timerConfig.OnCalendar')" '"*-*-* *:*:00"' \
  "Jellyfin user sync must run every minute."
require_json_equal "$(nix_eval_config_json 'systemd.timers.jellyfin-library-sync-v1.timerConfig.OnCalendar')" '"*-*-* *:*:00"' \
  "Jellyfin library sync must run every minute."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups."jellyfin-users".members')" '[]' \
  "Kanidm must provision the Jellyfin login group."
require_json_equal "$(nix_eval_config_json 'services.kanidm.provision.groups."jellyfin-admin".members')" "[\"admindsaw\"]" \
  "Kanidm must provision the Jellyfin admin-intent group."
require_json_equal "$(nix_eval_config_json 'systemd.services.audiobookshelf.serviceConfig.WorkingDirectory')" '"/var/lib/audiobookshelf"' \
  "Audiobookshelf state must live under /var/lib."
require_json_equal "$(nix_eval_config_json 'systemd.services.audiobookshelf-library-sync-v1.unitConfig.ConditionPathIsMountPoint')" '"/mnt/data"' \
  "Audiobookshelf library sync must be gated on the data pool mount."
require_json_equal "$(nix_eval_config_json 'systemd.services.kavita-library-sync-v1.unitConfig.ConditionPathIsMountPoint')" '"/mnt/data"' \
  "Kavita library sync must be gated on the data pool mount."
require_json_equal "$(nix_eval_config_json 'systemd.services.jellyfin-user-sync-v1.unitConfig.ConditionPathIsMountPoint')" '"/mnt/data"' \
  "Jellyfin user sync must be gated on the data pool mount."
require_json_equal "$(nix_eval_config_json 'systemd.services.jellyfin-library-sync-v1.unitConfig.ConditionPathIsMountPoint')" '"/mnt/data"' \
  "Jellyfin library sync must be gated on the data pool mount."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-sync.unitConfig.ConditionPathIsMountPoint')" '"/mnt/data"' \
  "Mail archive sync must be gated on the data pool mount."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-ui.serviceConfig.UMask')" '"0077"' \
  "Mail archive UI must set a restrictive UMask."
require_json_equal "$(nix_eval_config_json 'systemd.services.mail-archive-sync.serviceConfig.UMask')" '"0077"' \
  "Mail archive sync must set a restrictive UMask."
require_json_equal "$(nix_eval_config_json 'systemd.timers.mail-archive-sync.timerConfig.OnCalendar')" '"*-*-* 06,18:15:00"' \
  "Mail archive sync must keep the current schedule."
require_match rust/apps/mail-archive-ui/src/main.rs '\.route\("/accounts/\{id\}/edit"' \
  "Mail archive UI must expose the mailbox edit route."
require_match rust/apps/mail-archive-ui/src/main.rs '\.route\("/accounts/\{id\}/toggle-sync"' \
  "Mail archive UI must expose the mailbox schedule toggle route."
require_match rust/apps/mail-archive-ui/src/main.rs '\.route\("/accounts/\{id\}/reindex"' \
  "Mail archive UI must expose the mailbox reindex route."
require_fixed modules/Core_Modules/kanidm/account-policy.nix 'kanidm group account-policy auth-expiry' \
  "Kanidm must declaratively apply the account policy auth session expiry."
require_fixed modules/Core_Modules/kanidm/account-policy.nix 'idm_all_persons' \
  "Kanidm auth session grace must target the default people policy."

echo "ℹ️ Checking active tree for archived DietPi references…"
if rg -n -i 'dietpi|piLanIP|enableDietPiCompanion' \
  README.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain DietPi references."
  exit 1
fi

echo "ℹ️ Checking active tree for archived rust-scaffold references…"
if rg -n 'rust-scaffold|services\.rust-scaffold' \
  README.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain rust-scaffold references."
  exit 1
fi

echo "ℹ️ Checking active tree for the retired LAN IP…"
if rg -n '192\.168\.0\.144' \
  README.md AGENTS.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain the old LAN IP."
  exit 1
fi

echo "ℹ️ Checking active imports avoid archived content…"
forbid_match configuration.nix '_archive|superceded|apparmor|modules/rust' \
  "configuration.nix must not import archived modules."

echo "✅ Core config tests passed."
