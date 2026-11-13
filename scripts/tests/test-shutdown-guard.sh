#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash mktemp

guard="scripts/helpers/shutdown-guard.sh"
[[ -f "$guard" ]] || {
  echo "❌ Missing shutdown guard script: $guard" >&2
  exit 1
}

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

mock_bin="$tmpdir/bin"
flags="$tmpdir/flags"
state_dir="$tmpdir/state"
conf="$tmpdir/shutdown-guard.conf"
mkdir -p "$mock_bin" "$flags"

cat >"$conf" <<'EOF'
CRITICAL_UNITS=(kopia.service media-manager.service)
CRITICAL_PROCESSES=(rsync)
CRITICAL_PROCESS_PATTERNS=('gradle.*assembleRelease')
CRITICAL_COMMANDS=("test -e \"${MOCK_FLAGS}/command_busy\"")
EOF

cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  show)
    if [[ "$*" == *Environment* ]]; then
      [[ -e "${MOCK_FLAGS}/legacy_watcher" ]] || printf 'SHUTDOWN_GUARD_PROTOCOL=idle-only-v1\n'
      exit 0
    fi
    if { [[ -e "${MOCK_FLAGS}/active_until" ]] &&
         (( $(cat "${MOCK_FLAGS}/now") < $(cat "${MOCK_FLAGS}/active_until") )); } ||
       [[ -e "${MOCK_FLAGS}/systemctl_active" ]] ||
       { [[ -e "${MOCK_FLAGS}/active_at" ]] &&
         [[ "$(cat "${MOCK_FLAGS}/active_at")" == "$(cat "${MOCK_FLAGS}/now")" ]]; }; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    ;;
  *) printf '%s\n' "$*" >>"${MOCK_FLAGS}/systemctl.log"; exit 0 ;;
esac
EOF

cat >"$mock_bin/pgrep" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -f ]]; then
  [[ -e "${MOCK_FLAGS}/pgrep_pattern_busy" ]] && exit 0
else
  [[ -e "${MOCK_FLAGS}/pgrep_busy" ]] && exit 0
fi
exit 1
EOF

cat >"$mock_bin/date" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == +%s && -e "${MOCK_FLAGS}/now" ]]; then
  cat "${MOCK_FLAGS}/now"
else
  /bin/date "$@"
fi
EOF

cat >"$mock_bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [[ -e "${MOCK_FLAGS}/now" ]]; then
  now="$(cat "${MOCK_FLAGS}/now")"
  if [[ -e "${MOCK_FLAGS}/uptime" ]]; then
    printf '%s\n' "$(( $(cat "${MOCK_FLAGS}/uptime") + $1 ))" >"${MOCK_FLAGS}/uptime"
  fi
  if [[ -e "${MOCK_FLAGS}/extend_at" ]] && [[ "$now" == "$(cat "${MOCK_FLAGS}/extend_at")" ]]; then
    rm -f "${MOCK_FLAGS}/extend_at"
    nixhomeserver-shutdown-guard extend --minutes 10 --reason regression-check >/dev/null
  fi
  if [[ -e "${MOCK_FLAGS}/jump_to" ]]; then
    cat "${MOCK_FLAGS}/jump_to" >"${MOCK_FLAGS}/now"
    rm -f "${MOCK_FLAGS}/jump_to"
  else
    printf '%s\n' "$(( now + $1 ))" >"${MOCK_FLAGS}/now"
  fi
elif [[ "${MOCK_FAST_SLEEP:-}" == 1 ]]; then
  exit 0
else
  /bin/sleep "$@"
fi
EOF

cat >"$mock_bin/shutdown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_FLAGS}/shutdown.log"
[[ ! -e "${MOCK_FLAGS}/uptime" ]] || printf '%s %s\n' "$(cat "${MOCK_FLAGS}/uptime")" "$*" >>"${MOCK_FLAGS}/shutdown-monotonic.log"
[[ ! -e "${MOCK_FLAGS}/now" ]] || printf '%s %s\n' "$(cat "${MOCK_FLAGS}/now")" "$*" >>"${MOCK_FLAGS}/shutdown-times.log"
EOF

cat >"$mock_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_FLAGS}/systemd-run.log"
[[ ! -e "${MOCK_FLAGS}/systemd_run_fail" ]]
EOF

# Keep the desktop fixture independent of the host's login manager.
cat >"$mock_bin/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" == --* ]]; do shift; done
exec "$@"
EOF

cat >"$mock_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_FLAGS}/ssh.log"
[[ "$*" == *' true' ]] && exit 1
exit 0
EOF

cat >"$mock_bin/nixhomeserver-shutdown-guard" <<EOF
#!/usr/bin/env bash
exec bash "$TESTS_REPO_ROOT/$guard" "\$@"
EOF

make_test_executable \
  "$mock_bin/systemctl" \
  "$mock_bin/pgrep" \
  "$mock_bin/date" \
  "$mock_bin/sleep" \
  "$mock_bin/shutdown" \
  "$mock_bin/systemd-run" \
  "$mock_bin/ssh" \
  "$mock_bin/systemd-inhibit" \
  "$mock_bin/nixhomeserver-shutdown-guard"

export MOCK_FLAGS="$flags"
export SHUTDOWN_GUARD_STATE_DIR="$state_dir"
export SHUTDOWN_GUARD_CONF="$conf"
export SHUTDOWN_GUARD_UPTIME_FILE="$flags/uptime"
# Keep the fixture's explicit work signals independent of the host running it.
export SHUTDOWN_GUARD_LOAD_FACTOR=0
export SHUTDOWN_GUARD_RUNNABLE_THRESHOLD=0
export SHUTDOWN_GUARD_TTY_ACTIVITY_SEC=0
export PATH="$mock_bin:$PATH"

run_guard() {
  bash "$guard" "$@"
}

expect_equal() {
  local actual="$1" expected="$2" description="$3"
  if [[ "$actual" != "$expected" ]]; then
    echo "❌ ${description}" >&2
    echo "   Expected: ${expected}" >&2
    echo "   Actual:   ${actual}" >&2
    exit 1
  fi
}

# 1. Idle detection.
idle="$(run_guard check)"
expect_equal "$idle" "idle" "Guard should report idle when no critical task is active."

# 2. Active unit detection.
touch "$flags/systemctl_active"
busy="$(run_guard check)"
expect_equal "$busy" "busy unit:kopia.service" "Guard should report the first active critical unit."
rm -f "$flags/systemctl_active"

# 3. Active process detection.
touch "$flags/pgrep_busy"
busy_process="$(run_guard check)"
expect_equal "$busy_process" "busy process:rsync" "Guard should report an active critical process."
rm -f "$flags/pgrep_busy"

# 4. A command-line process pattern catches APK builds without matching idle daemons.
touch "$flags/pgrep_pattern_busy"
busy_pattern="$(run_guard check)"
expect_equal "$busy_pattern" "busy process-pattern:gradle.*assembleRelease" "Guard should report a matching APK build."
rm -f "$flags/pgrep_pattern_busy"

# 5. Recent desktop activity reaches the server guard and then expires after one
# activity window (five minutes).
printf '1000\n' >"$flags/now"
run_guard mark-activity >/dev/null
expect_equal "$(run_guard check)" "busy desktop:active-work" "Guard should see desktop activity."
printf '1361\n' >"$flags/now"
expect_equal "$(run_guard check)" "idle" "A stale desktop marker should not block shutdown."
rm -f "$flags/now"

# 6. Active command detection (used for ZFS scrub/resilver).
touch "$flags/command_busy"
busy_command="$(run_guard check)"
case "$busy_command" in
  "busy command:"*) : ;;
  *)
    echo "❌ Guard should report an active critical command." >&2
    echo "   Actual: $busy_command" >&2
    exit 1
    ;;
esac
rm -f "$flags/command_busy"

# 7. Dry run must not schedule anything.
: >"$flags/shutdown.log"
dry="$(run_guard start --timeout 5 --grace 5 --dry-run)"
if [[ "$dry" != dry-run:* ]]; then
  echo "❌ Dry run should describe the plan without scheduling." >&2
  echo "   Actual: $dry" >&2
  exit 1
fi
[[ ! -s "$flags/shutdown.log" ]] || {
  echo "❌ Dry run invoked shutdown." >&2
  exit 1
}

# 8. Real start schedules a shutdown and launches the watcher.
: >"$flags/shutdown.log"
: >"$flags/systemd-run.log"
run_guard start --timeout 7 --grace 3 --poll 1 >/dev/null
if rg -q -- '-h' "$flags/shutdown.log"; then
  echo "❌ Start must not arm an unconditional OS shutdown." >&2
  exit 1
fi
require_fixed "$flags/systemd-run.log" "watch --deadline" "Guard should launch the watcher."
require_fixed "$state_dir/status" "state=scheduled" "Guard should record the scheduled state."
[[ -s "$state_dir/deadline" ]] || {
  echo "❌ Guard should persist the shutdown deadline." >&2
  exit 1
}

# 8b. A failed watcher launch leaves no OS timer that could interrupt work.
: >"$flags/shutdown.log"
touch "$flags/systemd_run_fail"
if run_guard start --timeout 1 --grace 1 >/dev/null 2>&1; then
  echo "❌ A failed watcher launch must fail closed." >&2
  exit 1
fi
rm -f "$flags/systemd_run_fail"
if rg -q -- '-h' "$flags/shutdown.log"; then
  echo "❌ A failed watcher launch must not leave a queued poweroff." >&2
  exit 1
fi

# 9. Watcher with no critical task shuts down immediately at the deadline.
: >"$flags/shutdown.log"
rm -f "$state_dir/deadline" "$state_dir/grace-deadline" "$state_dir/grace-seconds"
printf '1000\n' >"$flags/now"
printf '1000\n' >"$flags/uptime"
run_guard watch --deadline 1 --grace-deadline 1 --poll 30
require_fixed "$flags/shutdown.log" "-h now" "Watcher should shut down after a full idle window."
require_fixed "$state_dir/status" "state=shutting-down" "Watcher should record the shutting-down state."

# 10. Work seen briefly in the final five minutes triggers grace and quiet time.
: >"$flags/shutdown.log"
rm -f "$state_dir/deadline" "$state_dir/grace-deadline"
printf '1000\n' >"$flags/now"
printf '1000\n' >"$flags/uptime"
printf '1060\n' >"$flags/active_at"
run_guard watch --deadline 1120 --grace-deadline 1720 --poll 30
rm -f "$flags/now" "$flags/active_at"
if rg -q -- '-h \+' "$flags/shutdown.log"; then
  echo "❌ Grace must not arm an unconditional OS shutdown." >&2
  exit 1
fi
require_fixed "$state_dir/status" "quiet for five minutes" "A momentary lull should not end grace immediately."

# Regression: the 2026-11-10 deployment was cut off after extend replaced
# queued grace. A queued timer and a hard grace cap must never interrupt work.
# 11. Work remains protected beyond the former six-hour cap, even if the clock
# jumps. Poweroff follows the last work plus five quiet minutes, not that cap.
: >"$flags/shutdown.log"
: >"$flags/shutdown-times.log"
rm -f "$state_dir/deadline" "$state_dir/grace-deadline"
printf '1000\n' >"$flags/now"
printf '1000\n' >"$flags/uptime"
printf '23000\n' >"$flags/jump_to"
printf '23030\n' >"$flags/active_until"
run_guard watch --deadline 1000 --grace-deadline 1000 --poll 30
rm -f "$flags/now" "$flags/active_until"
require_fixed "$flags/shutdown-times.log" "23330 -h now" \
  "Long work must finish and remain quiet for five minutes before poweroff."
require_fixed "$state_dir/status" "quiet for five minutes" "Active work must not expire."
expect_equal "$(cat "$state_dir/grace-deadline")" "23600" \
  "A delayed watcher should advance grace beyond the current clock."

# 11b. An explicit extension during the protected window still waits for work.
: >"$flags/shutdown.log"
: >"$flags/shutdown-times.log"
printf '1000\n' >"$flags/now"
printf '1000\n' >"$flags/uptime"
printf '1030\n' >"$flags/extend_at"
printf '1700\n' >"$flags/active_until"
printf '1120\n' >"$state_dir/deadline"
printf '1720\n' >"$state_dir/grace-deadline"
printf '600\n' >"$state_dir/grace-seconds"
run_guard watch --deadline 1120 --grace-deadline 1720 --poll 30
rm -f "$flags/now" "$flags/active_until"
require_fixed "$flags/shutdown-times.log" "2020 -h now" \
  "An extension must preserve ongoing work and the final quiet window."
if rg -q -- '-h \+' "$flags/shutdown.log"; then
  echo "❌ Extension must not arm an unconditional poweroff." >&2
  exit 1
fi

# 11c. A forward wall-clock jump does not shorten the five-minute idle window.
: >"$flags/shutdown-monotonic.log"
printf '1000\n' >"$flags/now"
printf '1000\n' >"$flags/uptime"
printf '23000\n' >"$flags/jump_to"
rm -f "$state_dir/deadline" "$state_dir/grace-deadline"
run_guard watch --deadline 1000 --grace-deadline 1000 --poll 30
require_fixed "$flags/shutdown-monotonic.log" "1300 -h now" \
  "A wall-clock jump must not shorten the measured quiet window."
rm -f "$flags/now"

# 12. extend pushes a pending shutdown later in a block and re-arms grace.
: >"$flags/shutdown.log"
rm -f "$state_dir/deadline" "$state_dir/grace-deadline"
printf '1000\n' >"$state_dir/deadline"
printf '1000\n' >"$state_dir/grace-deadline"
printf '3600\n' >"$state_dir/grace-seconds"
printf '1000\n' >"$flags/now"
run_guard extend --minutes 10 --reason "running validate-repo" >/dev/null
rm -f "$flags/now"
if rg -q -- '-h' "$flags/shutdown.log"; then
  echo "❌ extend must only move the logical deadline, not queue poweroff." >&2
  exit 1
fi
require_fixed "$state_dir/status" "extended" "extend should record the extended state."
expect_equal "$(cat "$state_dir/deadline")" "1600" "extend should persist the pushed deadline."
expect_equal "$(cat "$state_dir/grace-deadline")" "5200" "extend should re-arm the full grace window."

# 12b. Existing unsafe Nix-store watchers are replaced, retaining deadlines.
: >"$flags/systemd-run.log"
: >"$flags/systemctl.log"
touch "$flags/legacy_watcher"
printf '1000\n' >"$flags/now"
run_guard extend --minutes 10 >/dev/null
require_fixed "$flags/systemctl.log" "stop nixhomeserver-shutdown-guard.service" \
  "An active legacy watcher must be stopped before using the new protocol."
require_fixed "$flags/systemd-run.log" "SHUTDOWN_GUARD_PROTOCOL=idle-only-v1" \
  "The replacement watcher must advertise idle-only shutdown behavior."
require_fixed "$flags/systemd-run.log" "$TESTS_REPO_ROOT/$guard watch" \
  "Migration must launch the invoking helper rather than an old PATH executable."
expect_equal "$(cat "$state_dir/deadline")" "1600" "Migration must retain the extended deadline."
rm -f "$flags/legacy_watcher" "$flags/now"

# 13. extend refuses when no guarded shutdown is pending.
rm -f "$state_dir/deadline" "$state_dir/grace-deadline" "$state_dir/grace-seconds"
if run_guard extend --minutes 10 >/dev/null 2>&1; then
  echo "❌ extend should fail when no shutdown is scheduled." >&2
  exit 1
fi

# 12. The desktop script reports local work during the final five minutes.
: >"$flags/ssh.log"
touch "$flags/pgrep_busy"
MOCK_FAST_SLEEP=1 DESKTOP_SHUTDOWN_ALLOW_CONCURRENT=1 scripts/admin/desktop-server-shutdown.sh \
  --host test@server --timeout 1 --grace 10 --no-local-shutdown >/dev/null
rm -f "$flags/pgrep_busy"
require_fixed "$flags/ssh.log" "sudo nixhomeserver-shutdown-guard mark-activity" \
  "The desktop should relay build activity to the server guard."

echo "✅ Shutdown guard schedules, detects critical tasks, and enforces the grace window."
