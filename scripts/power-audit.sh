#!/usr/bin/env bash

set -euo pipefail

repo_root="${POWER_AUDIT_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

usage() {
  cat <<'EOF'
Usage: scripts/power-audit.sh

Read-only audit for the declarative power-management surface. It reports the
configured policy from Nix plus useful runtime signals from the current host.

Example:
  ./scripts/power-audit.sh
EOF
}

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "ERROR: Missing required tool: $tool"
      exit 1
    fi
  done
}

case "${1:-}" in
  "")
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

nix_var() {
  local expr="$1"
  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

nix_config_raw() {
  local attr="$1"
  local value
  value="$(nix eval --impure --raw --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
    in
      builtins.toJSON flake.nixosConfigurations.$(nix_var 'vars.hostname').config.${attr}
  ")"

  if [[ "$value" == \"*\" ]]; then
    value="${value#\"}"
    value="${value%\"}"
  fi

  printf '%s\n' "$value"
}

print_section() {
  local title="$1"
  echo
  echo "== ${title} =="
}

run_optional() {
  local label="$1"
  shift

  echo "-- ${label}"
  if "$@"; then
    :
  else
    echo "(command failed or requires additional privileges)"
  fi
}

need nix

hostname="$(nix_var 'vars.hostname')"
net_iface="$(nix_var 'vars.netIface')"
configured_governor="$(nix_config_raw 'powerManagement.cpuFreqGovernor')"
expected_governor="$configured_governor"
powertop_enabled="$(nix_config_raw 'powerManagement.powertop.enable')"
scsi_link_policy="$(nix_config_raw 'powerManagement.scsiLinkPolicy')"
nightly_suspend_calendar="$(nix_config_raw 'systemd.timers."power-management-nightly-suspend".timerConfig.OnCalendar')"
fstrim_schedule="$(nix_config_raw 'services.fstrim.interval')"

sudo_cmd=()
if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
  sudo_cmd=(sudo -n)
fi

print_section "Configured Policy"
printf 'Host: %s\n' "$hostname"
printf 'CPU governor: %s\n' "$configured_governor"
printf 'Powertop autotune: %s\n' "$powertop_enabled"
printf 'SCSI link policy: %s\n' "$scsi_link_policy"
printf 'Nightly suspend: %s\n' "$nightly_suspend_calendar"
printf 'fstrim schedule: %s\n' "$fstrim_schedule"
printf 'Primary interface: %s\n' "$net_iface"

print_section "Current Runtime Signals"
if command -v cpupower >/dev/null 2>&1; then
  run_optional "cpupower frequency-info" cpupower frequency-info
else
  echo "-- cpupower frequency-info"
  echo "(cpupower is not available in PATH)"
fi

if command -v turbostat >/dev/null 2>&1; then
  run_optional "turbostat sample" "${sudo_cmd[@]}" turbostat --quiet --show PkgWatt,BUSY%,Bzy_MHz,TSC_MHz --interval 5 --num_iterations 1
else
  echo "-- turbostat sample"
  echo "(turbostat is not available in PATH)"
fi

if command -v systemctl >/dev/null 2>&1; then
  run_optional "power-related timers" systemctl list-timers power-management-nightly-suspend.timer fstrim.timer zfs-scrub-data.timer
else
  echo "-- power-related timers"
  echo "(systemctl is not available in PATH)"
fi

if command -v journalctl >/dev/null 2>&1; then
  run_optional "nightly suspend journal" "${sudo_cmd[@]}" journalctl -u power-management-nightly-suspend -n 50 --no-pager
else
  echo "-- nightly suspend journal"
  echo "(journalctl is not available in PATH)"
fi

if command -v networkctl >/dev/null 2>&1; then
  run_optional "network interface status" networkctl status "$net_iface"
else
  echo "-- network interface status"
  echo "(networkctl is not available in PATH)"
fi

if command -v lsusb >/dev/null 2>&1; then
  run_optional "USB devices" lsusb
else
  echo "-- USB devices"
  echo "(lsusb is not available in PATH)"
fi

if command -v lspci >/dev/null 2>&1; then
  run_optional "PCI devices" lspci -nn
else
  echo "-- PCI devices"
  echo "(lspci is not available in PATH)"
fi

if command -v smartctl >/dev/null 2>&1; then
  run_optional "smartctl scan" "${sudo_cmd[@]}" smartctl --scan
else
  echo "-- smartctl scan"
  echo "(smartctl is not available in PATH)"
fi

print_section "Follow-up Areas"

current_governor_output="$(cpupower frequency-info 2>/dev/null || true)"
if ! grep -q "\"${expected_governor}\"" <<<"$current_governor_output"; then
  printf '* CPU governor does not appear to be `%s`; inspect `systemctl status cpufreq` and `cpupower frequency-info`.\n' "$expected_governor"
else
  printf '* CPU governor appears aligned with the configured `%s` policy.\n' "$expected_governor"
fi

skip_journal="$(journalctl -u power-management-nightly-suspend -n 50 --no-pager 2>/dev/null || true)"
if grep -q 'Skipping nightly suspend because blocker unit is active' <<<"$skip_journal"; then
  echo "* Nightly suspend has recently skipped because a blocker unit was active; review maintenance overlap before tightening the sleep window."
fi
if grep -q 'Skipping nightly suspend because an SSH session is active.' <<<"$skip_journal"; then
  echo "* Nightly suspend has recently skipped because of active SSH sessions; confirm this is expected operator activity."
fi
if grep -q 'Skipping nightly suspend because a non-root interactive session is active.' <<<"$skip_journal"; then
  echo "* Nightly suspend has recently skipped because of another interactive session; verify whether that is intentional."
fi

if command -v lsusb >/dev/null 2>&1; then
  usb_count="$(lsusb | wc -l | tr -d ' ')"
  if [[ "$usb_count" != "0" ]]; then
    echo "* USB devices are attached; if idle power remains high or a device misbehaves with autosuspend, review the lsusb list and add targeted usbAutoSuspend.denyList entries only for the affected devices."
  fi
fi

fstrim_timer_output="$(systemctl list-timers fstrim.timer --no-legend 2>/dev/null || true)"
if [[ -z "$fstrim_timer_output" ]]; then
  echo "* fstrim.timer was not listed; inspect systemctl status fstrim.timer and confirm the weekly trim schedule is active."
else
  echo "* fstrim.timer is present; confirm its next run stays in the evening maintenance window."
fi

echo "* Hardware-specific cleanup such as disabling Bluetooth, Wi-Fi, audio, LEDs, or individual device runtime PM remains manual by design. Audit the current lspci/lsusb output before making per-host changes."
