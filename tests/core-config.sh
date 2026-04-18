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
require_json_equal "$(nix_eval_config_json 'networking.defaultGateway')" "null" \
  "The gateway must be learned from DHCP rather than pinned in Nix."
require_json_equal "$(nix_eval_config_json "networking.interfaces.\"$(nix_eval_var 'vars.netIface')\".useDHCP")" "true" \
  "The primary LAN interface must use DHCP."
require_json_equal "$(nix_eval_config_json "networking.interfaces.\"$(nix_eval_var 'vars.netIface')\".ipv4.addresses")" "[]" \
  "The primary LAN interface must not keep a static IPv4 address block."
require_json_equal "$(nix_eval_config_json 'networking.nameservers')" '["127.0.0.1"]' \
  "The host must still resolve through the local Unbound instance."

echo "ℹ️ Checking data-disk stack extraction…"
require_json_equal "$(nix_eval_config_json 'fileSystems."/mnt/data".fsType')" '"fuse.mergerfs"' \
  "mergerfs must remain mounted at /mnt/data."
require_json_equal "$(nix_eval_config_json 'systemd.timers.snapraid-sync.timerConfig.OnCalendar')" '"*-*-* 22:00:00"' \
  "SnapRAID sync must keep the nightly timer."
require_json_equal "$(nix_eval_config_json 'systemd.timers.snapraid-scrub.timerConfig.OnCalendar')" '"Sun *-*-* 10:00:00"' \
  "SnapRAID scrub must keep the weekly timer."
require_json_equal "$(nix_eval_config_json 'services.smartd.enable')" "true" \
  "SMART monitoring must remain enabled."

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

echo "ℹ️ Checking active tree for removed gateway settings…"
if rg -n 'defaultGateway|192\.168\.0\.144' \
  README.md AGENTS.md documentation scripts modules configuration.nix vars.nix flake.nix \
  --glob '!_archive/**' >/dev/null; then
  echo "❌ Active tree must not retain removed gateway settings or the old LAN IP."
  exit 1
fi

echo "ℹ️ Checking active imports avoid archived content…"
forbid_match configuration.nix '_archive|superceded|apparmor|modules/rust' \
  "configuration.nix must not import archived modules."

echo "✅ Core config tests passed."
