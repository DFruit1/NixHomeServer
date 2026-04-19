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

echo "ℹ️ Checking storage topology config values…"
require_json_equal "$(nix_eval_json 'vars.dnsMode')" '"split-horizon"' \
  "vars.dnsMode must switch the host to split-horizon DNS."
require_json_equal "$(nix_eval_json 'builtins.length vars.dataDisks')" "3" \
  "vars.dataDisks must define exactly three protected data disks."
require_json_equal "$(nix_eval_json 'builtins.length vars.parityDisks')" "2" \
  "vars.parityDisks must define exactly two protected parity disks."
require_json_equal "$(nix_eval_json 'vars.backupDisk')" '"ata-ST500DM002-1BD142_W3TAKCTN"' \
  "vars.backupDisk must point at the active 500 GB backup disk."
require_json_equal "$(nix_eval_json 'vars.enableBackupDisk')" "true" \
  "vars.enableBackupDisk must keep the backup disk active."
require_json_equal "$(nix_eval_json 'vars.coldStorageDisk')" '"ata-HGST_HUS726040ALA610_K7G5W29L"' \
  "vars.coldStorageDisk must track the manual cold-storage disk."
require_json_equal "$(nix_eval_json 'vars.coldStorageMountPoint')" '"/mnt/cold-storage"' \
  "vars.coldStorageMountPoint must keep the manual mountpoint."
require_json_equal "$(nix_eval_json 'vars.mailArchiveStoreRoot')" '"/mnt/data/mail-archive"' \
  "Mail archive storage must resolve through mergerfs."
require_json_equal "$(nix_eval_json 'vars.usersWorkspaceRoot')" '"/mnt/data/workspaces/users"' \
  "Workspace roots must resolve through mergerfs."
require_json_equal "$(nix_eval_json 'vars.photosUploadRoot')" '"/mnt/data/media/photos/external"' \
  "Upload roots must resolve through mergerfs."

echo "ℹ️ Checking data-disk stack extraction…"
require_fixed configuration.nix './modules/Core_Modules/storage-monitoring' \
  "configuration.nix must import the storage-monitoring module."
require_json_equal "$(nix_eval_config_json 'fileSystems."/mnt/data".fsType')" '"fuse.mergerfs"' \
  "mergerfs must remain mounted at /mnt/data."
require_json_equal "$(nix_eval_config_json 'systemd.timers.snapraid-sync.timerConfig.OnCalendar')" '"*-*-* 22:00:00"' \
  "SnapRAID sync must keep the nightly timer."
require_json_equal "$(nix_eval_config_json 'systemd.timers.snapraid-scrub.timerConfig.OnCalendar')" '"Sun *-*-* 10:00:00"' \
  "SnapRAID scrub must keep the weekly timer."
require_json_equal "$(nix_eval_config_json 'services.smartd.enable')" "true" \
  "SMART monitoring must remain enabled."
smartd_devices="$(nix_eval_config_json 'services.smartd.devices')"
require_json_equal "$(printf '%s\n' "$smartd_devices" | jq 'length')" "6" \
  "smartd must monitor all configured data, parity, and backup disks."
require_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-ST500DM002-1BD142_W3TAKCTN" \
  "smartd must include the active backup disk."
forbid_json_contains "$(printf '%s\n' "$smartd_devices" | jq 'map(.device)')" "/dev/disk/by-id/ata-HGST_HUS726040ALA610_K7G5W29L" \
  "smartd must not monitor the manual cold-storage disk."
require_json_equal "$(nix_eval_config_json 'fileSystems."/mnt/backup".mountPoint')" '"/mnt/backup"' \
  "The backup disk must stay mounted at /mnt/backup."
require_json_contains "$(nix_eval_config_json 'fileSystems."/mnt/backup".options')" "nofail" \
  "The backup mount must tolerate a temporarily absent disk."
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-health-report".timerConfig.OnCalendar')" '"*:0/30"' \
  "Storage monitoring must generate the 30-minute report timer."
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-smart-short@disk1".timerConfig.OnCalendar')" '"Sat *-*-* 03:00:00"' \
  "disk1 must keep the weekly short SMART schedule."
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-smart-short@backupDisk".timerConfig.OnCalendar')" '"Sat *-*-* 04:40:00"' \
  "The backup disk must keep the weekly short SMART schedule when enabled."
require_json_equal "$(nix_eval_config_json 'systemd.timers."storage-smart-long@parity2".timerConfig.OnCalendar')" '"*-*-05 01:00:00"' \
  "parity2 must keep the monthly long SMART schedule."
require_json_equal "$(nix_eval_config_json 'fileSystems."/mnt/data".device')" '"/mnt/disk1:/mnt/disk2:/mnt/disk3"' \
  "mergerfs must contain only the three protected data mounts."
for active_mount in /mnt/disk1 /mnt/disk2 /mnt/disk3 /mnt/parity /mnt/parity2 /mnt/data; do
  require_json_contains "$(nix_eval_config_json "fileSystems.\"${active_mount}\".options")" "x-systemd.wanted-by=multi-user.target" \
    "${active_mount} must remain anchored under multi-user.target."
done
snapraid_config="$(nix_eval_config_raw 'environment.etc."snapraid.conf".text')"
require_match <(printf '%s\n' "$snapraid_config") '^parity /mnt/parity/snapraid\.parity$' \
  "SnapRAID must keep the primary parity directive."
require_match <(printf '%s\n' "$snapraid_config") '^2-parity /mnt/parity2/snapraid\.2-parity$' \
  "SnapRAID must keep the second parity directive."
require_json_equal "$(printf '%s\n' "$snapraid_config" | rg -c '^parity ')" "1" \
  "SnapRAID must emit exactly one parity directive."
require_json_equal "$(printf '%s\n' "$snapraid_config" | rg -c '^2-parity ')" "1" \
  "SnapRAID must emit exactly one 2-parity directive."
require_json_equal "$(printf '%s\n' "$snapraid_config" | rg -c '^data d[0-9]+ ')" "3" \
  "SnapRAID must emit exactly three data-disk directives."
require_match <(printf '%s\n' "$snapraid_config") '^content /mnt/parity/snapraid\.content$' \
  "SnapRAID must keep a content file on the first parity mount."
require_match <(printf '%s\n' "$snapraid_config") '^content /mnt/parity2/snapraid\.content$' \
  "SnapRAID must keep a content file on the second parity mount."
require_match <(printf '%s\n' "$snapraid_config") '^content /mnt/disk3/snapraid\.content$' \
  "SnapRAID must keep content files on all protected data mounts."
forbid_match <(printf '%s\n' "$snapraid_config") '^data d4 ' \
  "SnapRAID must not retain a fourth data-disk role."
forbid_match <(printf '%s\n' "$snapraid_config") '^data d5 ' \
  "SnapRAID must not retain a fifth data-disk role."
forbid_match <(printf '%s\n' "$snapraid_config") 'W3TAKCTN|K7G5W29L|/mnt/backup|/mnt/cold-storage' \
  "SnapRAID must not include the backup or cold-storage disks."
for legacy_dir in audiobookshelf copyparty immich jellyfin kavita paperless; do
  require_match <(printf '%s\n' "$snapraid_config") "^exclude /${legacy_dir}/$" \
    "SnapRAID must exclude the legacy /${legacy_dir} app-state path."
done
require_json_contains "$(nix_eval_config_json 'systemd.services.snapraid-sync.unitConfig.RequiresMountsFor')" "/mnt/parity2" \
  "snapraid-sync must wait for all configured parity mounts."
require_json_contains "$(nix_eval_config_json 'systemd.services.snapraid-scrub.unitConfig.RequiresMountsFor')" "/mnt/parity2" \
  "snapraid-scrub must wait for all configured parity mounts."

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
require_match modules/Core_Modules/caddy/default.nix '@copyparty_shares path /shares /shares/\*' \
  "Caddy must bypass oauth2-proxy only for the explicit Copyparty share namespace."
require_match modules/copyparty/default.nix 'shr = "/shares";' \
  "Copyparty must publish anonymous share links under /shares."
require_match modules/copyparty/default.nix '"shr-who" = "auth";' \
  "Copyparty share creation must be limited to authenticated users."
require_match modules/copyparty/default.nix 'r: @acct' \
  "The shared root must require authenticated Copyparty accounts."
require_match modules/copyparty/default.nix 'rwmda: @acct' \
  "Writable shared volumes must require authenticated Copyparty accounts."

echo "ℹ️ Checking cold-storage tooling…"
require_fixed modules/Core_Modules/storage/default.nix 'coldStorageMountPoint' \
  "Storage tmpfiles must create the cold-storage mountpoint."
require_fixed scripts/cold-storage.sh 'Usage: scripts/cold-storage.sh <status|mount|unmount>' \
  "The cold-storage helper must expose status, mount, and unmount."
require_fixed scripts/cold-storage.sh 'vars.coldStorageDisk' \
  "The cold-storage helper must resolve the disk from vars.nix."
require_fixed scripts/cold-storage.sh 'vars.coldStorageMountPoint' \
  "The cold-storage helper must resolve the mountpoint from vars.nix."

echo "ℹ️ Checking backup, power, and mail-archive essentials…"
require_json_equal "$(nix_eval_config_json 'services.restic.backups."server-state".repository')" "\"$(nix_eval_var 'vars.backupRepository')\"" \
  "Restic backups must target the canonical backup repository."
require_json_equal "$(nix_eval_config_json 'powerManagement.cpuFreqGovernor')" '"powersave"' \
  "Power management must retain the powersave governor."
require_json_equal "$(nix_eval_config_json 'systemd.timers.power-management-nightly-suspend.timerConfig.OnCalendar')" '"*-*-* 23:00:00"' \
  "Nightly suspend must keep the current schedule."
require_json_equal "$mail_archive_port" "9011" \
  "Mail archive UI must keep the expected local port."
require_json_equal "$(nix_eval_config_json 'systemd.timers.mail-archive-sync.timerConfig.OnCalendar')" '"*-*-* 06,18:15:00"' \
  "Mail archive sync must keep the current schedule."

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
