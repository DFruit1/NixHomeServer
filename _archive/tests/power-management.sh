#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg

net_iface="$(nix_eval_var 'vars.netIface')"
snapraid_sync_timer="$(nix_eval_var 'vars.snapraidSyncTimer')"
snapraid_scrub_timer="$(nix_eval_var 'vars.snapraidScrubTimer')"
fstrim_calendar="$(nix_eval_var 'vars.powerManagement.maintenance.fstrimCalendar')"

echo "ℹ️ Checking power-management source wiring…"
require_fixed configuration.nix './modules/power-management' \
  "configuration.nix must import the power-management module."
require_match vars.nix 'powerManagement = \{' \
  "vars.nix must declare the powerManagement attrset."
require_fixed vars.nix 'governor = "powersave";' \
  "vars.nix must declare the conservative CPU governor."
require_match vars.nix 'snapraidSyncTimer = ".*";' \
  "vars.nix must declare snapraidSyncTimer."
require_match vars.nix 'snapraidScrubTimer = ".*";' \
  "vars.nix must declare snapraidScrubTimer."
require_fixed vars.nix 'fstrimCalendar = "Sun *-*-* 19:00:00";' \
  "vars.nix must declare the explicit fstrim schedule."
require_fixed modules/power-management/default.nix 'rtcwake -m no -t "$wake_epoch"' \
  "The power-management module must program the RTC wake alarm before suspend."
require_fixed modules/power-management/default.nix 'cfg.sleep.blockerUnits' \
  "The power-management module must use the declared blocker units."
require_fixed modules/power-management/default.nix 'Skipping nightly suspend because an SSH session is active.' \
  "The power-management module must check for active SSH sessions before suspend."
require_fixed documentation/power-management.md './scripts/power-audit.sh' \
  "The power-management guide must document the power audit helper."
require_fixed documentation/operations.md './scripts/power-audit.sh' \
  "Operations must reference the power audit helper."

echo "ℹ️ Checking evaluated power-management config…"
require_json_equal "$(nix_eval_config_json "networking.interfaces.${net_iface}.wakeOnLan.enable")" "true" \
  "Wake-on-LAN must be enabled on vars.netIface."
require_json_equal "$(nix_eval_config_json "networking.interfaces.${net_iface}.wakeOnLan.policy")" '["magic"]' \
  "Wake-on-LAN policy must remain magic-packet based."
require_json_equal "$(nix_eval_config_json 'powerManagement.cpuFreqGovernor')" '"powersave"' \
  "The conservative CPU governor must remain powersave."
require_json_equal "$(nix_eval_config_json 'powerManagement.powertop.enable')" "true" \
  "Powertop autotune must remain enabled in the evaluated config."
require_json_equal "$(nix_eval_config_json 'powerManagement.scsiLinkPolicy')" '"med_power_with_dipm"' \
  "SATA/SCSI link power management must remain set to med_power_with_dipm."
require_json_equal "$(nix_eval_config_json 'services.fstrim.enable')" "true" \
  "Periodic fstrim must remain enabled."
require_json_equal "$(nix_eval_config_json 'services.fstrim.interval')" "\"${fstrim_calendar}\"" \
  "fstrim must remain scheduled from vars.powerManagement.maintenance.fstrimCalendar."
require_json_equal "$(nix_eval_config_json 'systemd.timers."power-management-nightly-suspend".timerConfig.OnCalendar')" '"*-*-* 23:00:00"' \
  "The nightly suspend timer must run at 23:00."
require_json_equal "$(nix_eval_config_json 'systemd.timers."power-management-nightly-suspend".timerConfig.Persistent')" "false" \
  "The nightly suspend timer must remain non-persistent."
require_json_equal "$(nix_eval_config_json 'systemd.timers."snapraid-sync".timerConfig.OnCalendar')" "\"${snapraid_sync_timer}\"" \
  "The SnapRAID sync timer must come from vars.snapraidSyncTimer."
require_json_equal "$(nix_eval_config_json 'systemd.timers."snapraid-scrub".timerConfig.OnCalendar')" "\"${snapraid_scrub_timer}\"" \
  "The SnapRAID scrub timer must come from vars.snapraidScrubTimer."

echo "✅ Power-management tests passed."
