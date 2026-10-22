#!/usr/bin/env bash
# Regression test for scripts/admin/install-temp-cleanup.sh.
#
# Pins the scheduled-job wiring: a cron block (or systemd user units when
# available), idempotent reinstallation, preserved unrelated crontab entries,
# the opt-out flags, and clean uninstall. Runs hermetically with fake crontab
# and systemctl binaries.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
ensure_tools awk

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

home="$root/home"
fakebin="$root/bin"
mkdir -p "$home" "$fakebin" "$root/scripts/admin"
cp "$TESTS_REPO_ROOT/scripts/admin/temp-cleanup.sh" "$root/scripts/admin/"
cp "$TESTS_REPO_ROOT/scripts/admin/install-temp-cleanup.sh" "$root/scripts/admin/"
chmod +x "$root/scripts/admin/temp-cleanup.sh" "$root/scripts/admin/install-temp-cleanup.sh"
installer="$root/scripts/admin/install-temp-cleanup.sh"

cat >"$fakebin/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  -l)
    if [[ -s "$FAKE_CRONTAB" ]]; then
      cat "$FAKE_CRONTAB"
    else
      exit 1
    fi
    ;;
  -)
    cat >"$FAKE_CRONTAB"
    ;;
  *)
    exit 2
    ;;
esac
EOF
cat >"$fakebin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--user" && "${2:-}" == "show-environment" ]]; then
  if [[ "${FAKE_SYSTEMD:-0}" == "1" ]]; then
    exit 0
  fi
  exit 1
fi
printf '%s\n' "$*" >>"$FAKE_SYSTEMCTL_LOG"
EOF
make_test_executable "$fakebin/crontab" "$fakebin/systemctl"

export FAKE_CRONTAB="$root/crontab.txt"
export FAKE_SYSTEMCTL_LOG="$root/systemctl.log"
: >"$FAKE_SYSTEMCTL_LOG"

run_installer() {
  HOME="$home" XDG_STATE_HOME="$home/.local/state" XDG_CONFIG_HOME="$home/.config" \
    PATH="$fakebin:$PATH" FAKE_SYSTEMD="${FAKE_SYSTEMD:-0}" \
    FAKE_CRONTAB="$FAKE_CRONTAB" FAKE_SYSTEMCTL_LOG="$FAKE_SYSTEMCTL_LOG" \
    bash "$installer" "$@"
}

echo "▶ temp cleanup scheduler installer"

# --- cron installation is idempotent and preserves other entries ------------

printf '%s\n' '15 2 * * * /usr/bin/backup --now' >"$FAKE_CRONTAB"
run_installer >/dev/null
run_installer >/dev/null

[[ "$(grep -c 'BEGIN nixhomeserver-temp-cleanup' "$FAKE_CRONTAB")" == 1 ]] \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ reinstall duplicated the crontab block" >&2; exit 1; }
grep -qF '15 2 * * * /usr/bin/backup --now' "$FAKE_CRONTAB" \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ an unrelated crontab entry was lost" >&2; exit 1; }
grep -qF '10 4 * * *' "$FAKE_CRONTAB" \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ the default 04:10 schedule was not installed" >&2; exit 1; }
grep -qF -- '--apply --include-scratch --include-worktrees' "$FAKE_CRONTAB" \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ the scheduled command is missing its safe defaults" >&2; exit 1; }
grep -qF "$home/.local/state/nixhomeserver/temp-cleanup.log" "$FAKE_CRONTAB" \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ the scheduled command does not log to state" >&2; exit 1; }

echo "  ✅ cron installation is idempotent and keeps unrelated entries"

# --- opt-out flags are honored ----------------------------------------------

run_installer --no-worktrees --no-scratch --time 05:07 >/dev/null
grep -qF '7 5 * * *' "$FAKE_CRONTAB" \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ --time was not applied" >&2; exit 1; }
if grep -q -- '--include-worktrees\|--include-scratch' "$FAKE_CRONTAB"; then
  cat "$FAKE_CRONTAB" >&2
  echo "❌ an opt-out flag remained in the scheduled command" >&2
  exit 1
fi

echo "  ✅ --no-worktrees, --no-scratch and --time are honored"

# --- uninstall preserves unrelated entries ----------------------------------

run_installer --uninstall >/dev/null
grep -qF 'BEGIN nixhomeserver-temp-cleanup' "$FAKE_CRONTAB" \
  && { cat "$FAKE_CRONTAB" >&2; echo "❌ uninstall left the crontab block" >&2; exit 1; }
grep -qF '15 2 * * * /usr/bin/backup --now' "$FAKE_CRONTAB" \
  || { cat "$FAKE_CRONTAB" >&2; echo "❌ uninstall removed an unrelated crontab entry" >&2; exit 1; }

echo "  ✅ uninstall removes only its own block"

# --- a systemd user manager takes precedence --------------------------------

export FAKE_SYSTEMD=1
run_installer >/dev/null
service="$home/.config/systemd/user/nixhomeserver-temp-cleanup.service"
timer="$home/.config/systemd/user/nixhomeserver-temp-cleanup.timer"
[[ -f "$service" && -f "$timer" ]] \
  || { echo "❌ systemd user units were not written" >&2; exit 1; }
grep -qF -- '--apply --include-scratch --include-worktrees' "$service" \
  || { cat "$service" >&2; echo "❌ the systemd service is missing its safe defaults" >&2; exit 1; }
grep -qF 'OnCalendar=*-*-* 4:10:00' "$timer" \
  || { cat "$timer" >&2; echo "❌ the systemd timer schedule is wrong" >&2; exit 1; }
grep -q 'enable --now nixhomeserver-temp-cleanup.timer' "$FAKE_SYSTEMCTL_LOG" \
  || { cat "$FAKE_SYSTEMCTL_LOG" >&2; echo "❌ the timer was not enabled" >&2; exit 1; }

run_installer --uninstall >/dev/null
[[ ! -e "$service" && ! -e "$timer" ]] \
  || { echo "❌ uninstall left systemd units behind" >&2; exit 1; }

echo "  ✅ systemd user timer installation takes precedence and uninstalls cleanly"
echo "✅ temp cleanup scheduler installer contract passed"
