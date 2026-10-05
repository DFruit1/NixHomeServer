#!/usr/bin/env bash
# Executable regression test for scripts/hermes/simplex-chat-daemon.sh.
#
# Why this needs pinning
# ----------------------
# install-board-wiring.sh only compares the installed supervisor against the
# tracked file byte for byte, so every defect inside the supervisor shipped
# unnoticed. The properties below are what actually make the arrangement safe,
# and none of them are visible in the source:
#
#   * one daemon per identity database -- the lock has to be taken BEFORE the
#     seed launch, not after it. On a virgin state directory the seed launch is
#     the one that creates the profile, so two first runs (autostart plus a
#     manual invocation) used to both create the same identity concurrently.
#   * --once must actually run the daemon and hand back its exit status. It used
#     to `exec run_daemon`, and exec cannot take a shell function, so every
#     --once exited 127 without starting anything.
#   * --once used to run before the lock was taken, so an explicit request could
#     open a second daemon on a live database while looking like a success.
#   * the seed run's -y (--yes-migrate) was passed to a function that dropped it,
#     so an unattended schema bump waited on a prompt nobody can see.
#
# Hermetic: a fake daemon binary under a fixture HERMES_ROOT, and a fixture
# SIMPLEX_STATE_DIR and XDG_RUNTIME_DIR so the real lock file and the real bot
# identity are never touched. No network, no real daemon, no board.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUPERVISOR="$TESTS_REPO_ROOT/scripts/hermes/simplex-chat-daemon.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

[[ -x "$SUPERVISOR" ]] || fail "simplex-chat-daemon.sh is not executable"

for tool in awk bash flock mktemp seq timeout; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is not on PATH"
done

fixture="$(mktemp -d)"
# Any supervisor or fake daemon still alive at exit is killed by name, so a
# failed assertion cannot leave a process holding the fixture lock.
cleanup() {
  local leaked
  # pgrep can list several pids, so it is read line by line: one quoted argument
  # holding "123\n456" is not a valid kill argument list.
  while read -r leaked; do
    [[ -n "$leaked" ]] || continue
    kill "$leaked" 2>/dev/null || true
  done < <(pgrep -f "$fixture/" 2>/dev/null || true)
  rm -rf "$fixture"
}
trap cleanup EXIT

# One fake binary serves every case. It derives the database path from the -d it
# was given (the real layout puts the database beside simplex_v1), records its
# whole argument list, then either lingers or exits with the requested status.
FAKE_DAEMON="$fixture/fake-daemon"
cat >"$FAKE_DAEMON" <<'SH'
#!/usr/bin/env bash
set -uo pipefail

printf 'RUN %s\n' "$*" >>"$FAKE_DAEMON_LOG"

data_dir=""
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-d" ]]; then
    data_dir="$arg"
    break
  fi
  prev="$arg"
done

if [[ -n "$data_dir" ]]; then
  # The real daemon only opens its chat server once the database exists, which
  # is what the supervisor's seed wait polls for.
  touch "${data_dir}_chat.db"
fi

sleep "${FAKE_DAEMON_SLEEP:-0}"
exit "${FAKE_DAEMON_EXIT:-0}"
SH
chmod +x "$FAKE_DAEMON"

# A fresh fixture root per case: HERMES_ROOT for the binary, SIMPLEX_STATE_DIR
# for the identity, XDG_RUNTIME_DIR for the lock. case_root is exported so the
# fake can be found by the cleanup pgrep above.
new_case() {
  case_root="$fixture/case-$1"
  rm -rf "$case_root"
  mkdir -p "$case_root/hermes/simplex-chat/bin" "$case_root/state" "$case_root/run"
  cp "$FAKE_DAEMON" "$case_root/hermes/simplex-chat/bin/simplex-chat"
  chmod +x "$case_root/hermes/simplex-chat/bin/simplex-chat"
  : >"$case_root/daemon.log"

  HERMES_ROOT="$case_root/hermes"
  SIMPLEX_STATE_DIR="$case_root/state"
  XDG_RUNTIME_DIR="$case_root/run"
  FAKE_DAEMON_LOG="$case_root/daemon.log"
  # Defaults per case; individual assertions override them.
  FAKE_DAEMON_SLEEP=0
  FAKE_DAEMON_EXIT=0
  export HERMES_ROOT SIMPLEX_STATE_DIR XDG_RUNTIME_DIR FAKE_DAEMON_LOG
  export FAKE_DAEMON_SLEEP FAKE_DAEMON_EXIT
}

run_supervisor() { "$SUPERVISOR" "$@"; }

launch_count() { grep -c '^RUN ' "$FAKE_DAEMON_LOG" 2>/dev/null || true; }

# ---------------------------------------------------------------------------

echo "▶ simplex supervisor: one-shot execution"

new_case once-exit
set +e
once_out="$(run_supervisor --once 2>&1)"
once_rc=$?
set -e

[[ "$once_rc" == 0 ]] ||
  fail "--once exited $once_rc instead of running the daemon: $once_out"
grep -qi 'not found' <<<"$once_out" &&
  fail "--once reported a missing command, which is the exec-of-a-function defect"
# This fixture is virgin, so --once seeds first and then runs once. Exactly one
# of those two launches may be an unsupervised run.
seed_launches="$(grep -c '^RUN .*-y' "$FAKE_DAEMON_LOG" 2>/dev/null || true)"
unsupervised="$(( $(launch_count) - seed_launches ))"
[[ "$unsupervised" == 1 ]] ||
  fail "--once ran the daemon $unsupervised times; it must run it exactly once
$(cat "$FAKE_DAEMON_LOG")"
run_line="$(grep -v '^RUN .* -y' "$FAKE_DAEMON_LOG" | tail -n 1)"
for expected in "-d $SIMPLEX_STATE_DIR/simplex_v1" "-p 5225" "--user-display-name Hermes Agent"; do
  [[ " $run_line " == *" $expected "* ]] ||
    fail "--once did not forward '$expected' to the binary: $run_line"
done
pass "--once runs the binary once with the expected arguments"

new_case once-status
FAKE_DAEMON_EXIT=23
set +e
run_supervisor --once >/dev/null 2>&1
status_rc=$?
set -e
[[ "$status_rc" == 23 ]] ||
  fail "--once returned $status_rc, not the daemon's 23"
pass "--once returns the daemon's exit status"

new_case once-passthru
run_supervisor --once -- -y --yes-migrate >/dev/null 2>&1 ||
  fail "--once rejected an operator argument after --"
run_line="$(grep '^RUN ' "$FAKE_DAEMON_LOG" | tail -n 1)"
[[ " $run_line " == *" -y --yes-migrate "* ]] ||
  fail "arguments after -- were not forwarded verbatim: $run_line"
# Operator arguments go last so they can override a wrapper default.
[[ "$run_line" == *"-y --yes-migrate" ]] ||
  fail "operator arguments must follow the wrapper's own: $run_line"
pass "--once forwards arguments after -- verbatim, last"

# ---------------------------------------------------------------------------

echo "▶ simplex supervisor: seeding"

new_case seed-migrate
run_supervisor --once >/dev/null 2>&1 ||
  fail "a virgin state directory did not seed and run"
seed_line="$(grep '^RUN .*-y' "$FAKE_DAEMON_LOG" | head -n 1)"
[[ -n "$seed_line" ]] ||
  fail "the seed launch did not carry -y/--yes-migrate: $(cat "$FAKE_DAEMON_LOG")"
[[ "$(grep -c '^RUN .*-y' "$FAKE_DAEMON_LOG")" == 1 ]] ||
  fail "expected exactly one seed launch, got $(grep -c '^RUN .*-y' "$FAKE_DAEMON_LOG")"
[[ -f "$SIMPLEX_STATE_DIR/simplex_v1_chat.db" ]] ||
  fail "the seed launch left no profile behind"
pass "the seed launch carries -y and creates the profile"

new_case seed-fails
cat >"$HERMES_ROOT/simplex-chat/bin/simplex-chat" <<'SH'
#!/usr/bin/env bash
exit 9
SH
chmod +x "$HERMES_ROOT/simplex-chat/bin/simplex-chat"
set +e
seed_out="$(run_supervisor --once 2>&1)"
seed_rc=$?
set -e
[[ "$seed_rc" != 0 ]] ||
  fail "a seed launch that never creates a profile must not report success"
[[ "$seed_rc" != 127 ]] ||
  fail "the seed wait returned the old exec-of-a-function defect"
grep -qi 'did not create a profile' <<<"$seed_out" ||
  fail "a failed seed did not say so: $seed_out"
pass "a seed launch that creates no profile fails loudly"

# ---------------------------------------------------------------------------

echo "▶ simplex supervisor: single instance"

# Hold the lock the way the supervisor does, so the refusal paths can be
# exercised without racing a real supervised loop.
hold_lock() {
  rm -f "$case_root/lock-held"
  (
    exec 9>"$XDG_RUNTIME_DIR/hermes-simplex-daemon.lock"
    flock 9 || exit 1
    # Readiness marker: flock has no "tell me who holds this" query, and a
    # probe that took the lock itself would release it again.
    : >"$case_root/lock-held"
    sleep 30
  ) &
  holder_pid=$!
  local waited=0
  while [[ ! -e "$case_root/lock-held" ]]; do
    (( waited += 1 ))
    [[ "$waited" -lt 100 ]] || fail "the lock holder never took the lock"
    sleep 0.1
  done
}

new_case lock-once-refused
hold_lock
set +e
refused_out="$(run_supervisor --once 2>&1)"
refused_rc=$?
set -e
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

[[ "$refused_rc" != 0 ]] ||
  fail "--once succeeded while another daemon held the lock"
[[ "$(launch_count)" == 0 ]] ||
  fail "--once launched a daemon against a locked database"
grep -q 'already holds' <<<"$refused_out" ||
  fail "--once did not report the lock refusal: $refused_out"
pass "--once refuses to run beside a live daemon, and launches nothing"

new_case lock-supervised-noop
hold_lock
set +e
noop_out="$(run_supervisor 2>&1)"
noop_rc=$?
set -e
kill "$holder_pid" 2>/dev/null || true
wait "$holder_pid" 2>/dev/null || true

[[ "$noop_rc" == 0 ]] ||
  fail "a second supervised launch exited $noop_rc; autostart plus manual use is normal"
[[ "$(launch_count)" == 0 ]] ||
  fail "a second supervised launch started a daemon anyway"
grep -q 'already supervised' <<<"$noop_out" ||
  fail "the second launch did not say a daemon is already supervised: $noop_out"
pass "a second supervised launch is a reported no-op, not a second daemon"

# ---------------------------------------------------------------------------

echo "▶ simplex supervisor: concurrent virgin-state startup"

# The property the lock ordering exists for: on a state directory with no
# profile, several simultaneous first runs must still produce exactly one seed
# launch and exactly one supervised launch. Three supervisors start together
# while the fake lingers, so any launch made before the lock is held would be
# recorded.
new_case concurrent-virgin
FAKE_DAEMON_SLEEP=3

# $SUPERVISOR, not run_supervisor: timeout execs a program and cannot run a
# shell function. The timeout bounds the supervise restart loop, which never
# exits on its own.
set +e
timeout -k 2 12 "$SUPERVISOR" >"$case_root/sup-1.out" 2>&1 &
first=$!
timeout -k 2 12 "$SUPERVISOR" >"$case_root/sup-2.out" 2>&1 &
second=$!
timeout -k 2 12 "$SUPERVISOR" >"$case_root/sup-3.out" 2>&1 &
third=$!
wait "$first" "$second" "$third"
set -e

seed_launches="$(grep -c '^RUN .*-y' "$FAKE_DAEMON_LOG" 2>/dev/null || true)"
supervised_launches="$(( $(launch_count) - seed_launches ))"

[[ "$seed_launches" == 1 ]] ||
  fail "concurrent first runs seeded the identity $seed_launches times; it must be exactly once:
$(cat "$FAKE_DAEMON_LOG")"
[[ "$supervised_launches" == 1 ]] ||
  fail "concurrent first runs supervised $supervised_launches daemons; exactly one may hold the database:
$(cat "$FAKE_DAEMON_LOG")"

already_supervised="$(cat "$case_root"/sup-*.out | grep -c 'already supervised' || true)"
[[ "$already_supervised" -ge 1 ]] ||
  fail "no losing launch reported that a daemon was already supervised:
$(cat "$case_root"/sup-*.out)"
pass "three concurrent virgin-state launches yield one seed and one supervised daemon"

# ---------------------------------------------------------------------------

echo "▶ simplex supervisor: argument handling and the read-only check"

new_case usage
set +e
run_supervisor --bogus >"$case_root/usage.out" 2>&1
usage_rc=$?
set -e
[[ "$usage_rc" == 2 ]] ||
  fail "an unknown flag exited $usage_rc; it must exit 2"
pass "an unknown flag exits 2 with usage"

new_case check
check_out="$(run_supervisor --check 2>&1)" ||
  fail "--check exited non-zero: $check_out"
grep -q 'need attention' <<<"$check_out" ||
  fail "--check reported no drift on an unwired fixture: $check_out"
[[ "$(launch_count)" == 0 ]] ||
  fail "--check launched the daemon; it must change nothing"
[[ ! -e "$XDG_RUNTIME_DIR/hermes-simplex-daemon.lock" ]] ||
  fail "--check took the single-instance lock; it must stay read-only"
[[ ! -f "$SIMPLEX_STATE_DIR/simplex_v1_chat.db" ]] ||
  fail "--check created a profile; it must change nothing"
pass "--check stays read-only: no launch, no lock, no profile"

echo "✅ simplex supervisor regressions passed"