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
    if [[ -e "${MOCK_FLAGS}/systemctl_active" ]] ||
       { [[ -e "${MOCK_FLAGS}/active_at" ]] &&
         [[ "$(cat "${MOCK_FLAGS}/active_at")" == "$(cat "${MOCK_FLAGS}/now")" ]]; }; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    ;;
  *) exit 0 ;;
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
  printf '%s\n' "$(( $(cat "${MOCK_FLAGS}/now") + $1 ))" >"${MOCK_FLAGS}/now"
elif [[ "${MOCK_FAST_SLEEP:-}" == 1 ]]; then
  exit 0
else
  /bin/sleep "$@"
fi
EOF

cat >"$mock_bin/shutdown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_FLAGS}/shutdown.log"
EOF

cat >"$mock_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${MOCK_FLAGS}/systemd-run.log"
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
  "$mock_bin/nixhomeserver-shutdown-guard"

export MOCK_FLAGS="$flags"
export SHUTDOWN_GUARD_STATE_DIR="$state_dir"
export SHUTDOWN_GUARD_CONF="$conf"
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

# 5. Recent desktop activity reaches the server guard and then expires.
printf '1000\n' >"$flags/now"
run_guard mark-activity >/dev/null
expect_equal "$(run_guard check)" "busy desktop:active-work" "Guard should see desktop activity."
printf '1061\n' >"$flags/now"
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
require_fixed "$flags/shutdown.log" "-h +7" "Guard should schedule a shutdown at the timeout."
require_fixed "$flags/systemd-run.log" "watch --deadline" "Guard should launch the watcher."
require_fixed "$state_dir/status" "state=scheduled" "Guard should record the scheduled state."

# 9. Watcher with no critical task shuts down immediately at the deadline.
: >"$flags/shutdown.log"
run_guard watch --deadline 1 --grace-deadline 1 --poll 1
require_fixed "$flags/shutdown.log" "-h now" "Watcher should shut down when no critical task is active."
require_fixed "$state_dir/status" "state=shutting-down" "Watcher should record the shutting-down state."

# 10. Work seen briefly in the final five minutes triggers grace and quiet time.
: >"$flags/shutdown.log"
printf '1000\n' >"$flags/now"
printf '1060\n' >"$flags/active_at"
run_guard watch --deadline 1120 --grace-deadline 1720 --poll 30
rm -f "$flags/now" "$flags/active_at"
require_fixed "$flags/shutdown.log" "-h +11" "Activity before the deadline should schedule grace early."
require_fixed "$state_dir/status" "quiet for five minutes" "A momentary lull should not end grace immediately."

# 11. Watcher with an active task past the grace window stops at the backstop.
: >"$flags/shutdown.log"
touch "$flags/systemctl_active"
run_guard watch --deadline 1 --grace-deadline 1 --poll 1
rm -f "$flags/systemctl_active"
require_fixed "$flags/shutdown.log" "-h now" "Watcher should still shut down after the grace window."
require_fixed "$state_dir/status" "grace expired" "Watcher should record that the grace window expired."

# 12. The desktop script reports local work during the final five minutes.
: >"$flags/ssh.log"
touch "$flags/pgrep_busy"
MOCK_FAST_SLEEP=1 scripts/admin/desktop-server-shutdown.sh \
  --host test@server --timeout 1 --grace 10 --no-local-shutdown >/dev/null
rm -f "$flags/pgrep_busy"
require_fixed "$flags/ssh.log" "sudo nixhomeserver-shutdown-guard mark-activity" \
  "The desktop should relay build activity to the server guard."

echo "✅ Shutdown guard schedules, detects critical tasks, and enforces the grace window."
