#!/usr/bin/env bash
# Install a daily Hermes and development temp cleanup for the current user.
#
# Uses a systemd user timer when one is available (NixOS workstations) and the
# user's crontab otherwise (Void/runit workstations). The job runs the dry-run-
# safe scripts/admin/temp-cleanup.sh with --apply; every deletion is governed by
# that script's allowlist, age gates and protected-content checks.
#
# The installation is idempotent and reversible with --uninstall. It never
# touches other cron entries or unit files.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
cleanup="$repo_root/scripts/admin/temp-cleanup.sh"

state_root="${XDG_STATE_HOME:-$HOME/.local/state}"
log_file="$state_root/nixhomeserver/temp-cleanup.log"
begin_marker="# BEGIN nixhomeserver-temp-cleanup"
end_marker="# END nixhomeserver-temp-cleanup"

apply=true
uninstall=false
include_scratch=true
include_worktrees=true
time_of_day="04:10"

usage() {
  cat <<'EOF'
Usage: install-temp-cleanup.sh [--uninstall] [--dry-run] [--no-worktrees]
                               [--no-scratch] [--time HH:MM] [-h]

Install (or remove) the daily Hermes and development temp cleanup for this user.

  --uninstall       Remove the timer or crontab block installed earlier.
  --dry-run         Print the planned changes without applying them.
  --no-worktrees    Do not prune worktrees in the scheduled run (caches, logs,
                    scratch and generated output are still cleaned).
  --no-scratch      Do not clean dormant Hermes profile scratch directories.
  --time HH:MM      Daily run time in local time (default 04:10).
  -h, --help        Show this help.

The scheduled job runs scripts/admin/temp-cleanup.sh --apply; that script keeps
its own allowlist, retention gates and protected-content checks. Run it once
without --apply to review what it would remove.
EOF
}

while (($# > 0)); do
  case "$1" in
    --uninstall) uninstall=true; shift ;;
    --apply) apply=true; shift ;;
    --dry-run) apply=false; shift ;;
    --no-worktrees) include_worktrees=false; shift ;;
    --no-scratch) include_scratch=false; shift ;;
    --time) [[ $# -ge 2 ]] || { echo "❌ --time needs HH:MM" >&2; exit 2; }; time_of_day="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$time_of_day" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
  echo "❌ --time must look like 04:10" >&2
  exit 2
fi
hour="${BASH_REMATCH[1]}"
minute="${BASH_REMATCH[2]}"
# Strip a leading zero so crontab and systemd both read the value as decimal.
hour="$((10#$hour))"
minute="$((10#$minute))"

if [[ ! -x "$cleanup" ]]; then
  echo "❌ Missing cleanup script: $cleanup" >&2
  exit 1
fi

cleanup_args=(--apply)
if [[ "$include_scratch" == true ]]; then
  cleanup_args+=(--include-scratch)
fi
if [[ "$include_worktrees" == true ]]; then
  cleanup_args+=(--include-worktrees)
fi
command_line="$cleanup ${cleanup_args[*]}"

has_systemd_user() {
  command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1
}

has_cron() {
  command -v crontab >/dev/null 2>&1
}

install -d -m 0755 -- "$(dirname -- "$log_file")"

unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
service_file="$unit_dir/nixhomeserver-temp-cleanup.service"
timer_file="$unit_dir/nixhomeserver-temp-cleanup.timer"

print_plan() {
  printf '  %s\n' "$@"
}

install_systemd_units() {
  install -d -m 0755 -- "$unit_dir"
  cat >"$service_file" <<EOF
[Unit]
Description=NixHomeServer Hermes and development temp cleanup

[Service]
Type=oneshot
ExecStart=$command_line
Environment=HOME=%h
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
Nice=15
EOF
  cat >"$timer_file" <<EOF
[Unit]
Description=Daily NixHomeServer Hermes and development temp cleanup

[Timer]
OnCalendar=*-*-* ${hour}:${minute}:00
Persistent=true
RandomizedDelaySec=15m

[Install]
WantedBy=timers.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now nixhomeserver-temp-cleanup.timer
}

cron_block() {
  printf '%s\n' "$begin_marker"
  printf '%s %s * * * %s >>%s 2>&1\n' "$minute" "$hour" "$command_line" "$log_file"
  printf '%s\n' "$end_marker"
}

current_crontab() {
  crontab -l 2>/dev/null || true
}

strip_cron_block() {
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  '
}

install_cron() {
  local existing filtered
  existing="$(current_crontab)"
  filtered="$(strip_cron_block <<<"$existing")"
  {
    if [[ -n "$filtered" ]]; then
      printf '%s\n' "$filtered"
    fi
    cron_block
  } | crontab -
}

uninstall_systemd_units() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now nixhomeserver-temp-cleanup.timer 2>/dev/null || true
  fi
  rm -f -- "$service_file" "$timer_file"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
}

uninstall_cron() {
  local existing filtered
  existing="$(current_crontab)"
  grep -qF -- "$begin_marker" <<<"$existing" || return 0
  filtered="$(strip_cron_block <<<"$existing")"
  printf '%s\n' "$filtered" | crontab -
}

if [[ "$uninstall" == true ]]; then
  if has_systemd_user || [[ -f "$service_file" || -f "$timer_file" ]]; then
    if [[ "$apply" == true ]]; then
      uninstall_systemd_units
      echo "✅ Removed the systemd user timer (log kept at $log_file)."
    else
      print_plan "would remove $service_file and $timer_file"
    fi
  fi
  if has_cron; then
    if [[ "$apply" == true ]]; then
      uninstall_cron
      echo "✅ Removed the crontab block (log kept at $log_file)."
    else
      print_plan "would remove the $begin_marker crontab block"
    fi
  fi
  exit 0
fi

if has_systemd_user; then
  if [[ "$apply" == true ]]; then
    install_systemd_units
    echo "✅ Installed nixhomeserver-temp-cleanup.timer for ${hour}:$(printf '%02d' "$minute") daily."
    echo "   Command: $command_line"
    echo "   Log:     $log_file"
  else
    print_plan "would write $service_file and $timer_file" \
      "would enable nixhomeserver-temp-cleanup.timer at ${hour}:$(printf '%02d' "$minute")"
  fi
elif has_cron; then
  if [[ "$apply" == true ]]; then
    install_cron
    echo "✅ Installed the daily temp cleanup crontab block at ${hour}:$(printf '%02d' "$minute")."
    echo "   Command: $command_line"
    echo "   Log:     $log_file"
  else
    print_plan "would write the $begin_marker crontab block at ${hour}:$(printf '%02d' "$minute")"
  fi
else
  echo "❌ Neither a systemd user manager nor crontab is available." >&2
  exit 1
fi
