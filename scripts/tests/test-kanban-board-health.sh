#!/usr/bin/env bash
# Regression test for scripts/hermes/kanban-board-health.sh.
#
# Why this needs pinning
# ----------------------
# The script is wired as a hermes cron `--monitor-script`, and the cron monitor
# suppresses the head-coordinator's run by hashing the script's stdout byte-for-
# byte. Two
# failure modes are therefore silent and expensive:
#
#   * Output that is not perfectly stable. A timestamp, a pid, an exact age, or
#     a filesystem path changes every run, so the hash changes every run, so the
#     head-coordinator is woken every 30 minutes forever and learns to ignore the
#     job.
#   * Output that is empty when it should not be, or vice versa. A missed
#     detection means a card starves silently; a spurious one burns the
#     head-coordinator.
#
# Both are invisible in normal use, so they are pinned here against a synthetic
# board. The script is exercised through its real entry point with a fixture
# HERMES_ROOT, so the SQL, the config parser and the age bucketing are all
# covered together -- the seams are where this kind of script breaks.
#
# The git half is pinned too, because an UNPUSHED verdict that is wrong in
# either direction is worse than no verdict: a false negative loses work, a
# false positive sends the head-coordinator chasing branches that were never at
# risk.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HEALTH="$TESTS_REPO_ROOT/scripts/hermes/kanban-board-health.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

[[ -x "$HEALTH" ]] || fail "kanban-board-health.sh is not executable"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

BOARD_DIR="$fixture/hermes/kanban/boards/testboard"
mkdir -p "$BOARD_DIR"
DB="$BOARD_DIR/kanban.db"

sqlite3 "$DB" <<'SQL'
CREATE TABLE tasks (
  id TEXT PRIMARY KEY,
  title TEXT,
  assignee TEXT,
  status TEXT,
  created_at INTEGER,
  started_at INTEGER,
  claim_lock TEXT,
  worker_pid INTEGER,
  last_heartbeat_at INTEGER,
  block_recurrences INTEGER DEFAULT 0
);
CREATE TABLE task_comments (id INTEGER PRIMARY KEY, task_id TEXT, body TEXT);
SQL

now="$(date +%s)"

# A card the dispatcher cannot spawn into: ready, unclaimed, stale past the
# threshold. This is the exact shape of the bug that went unnoticed for hours.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_stale','stale ready card','local-implementer','ready',$now-7200,$now-7200,NULL,NULL,$now-7200,0);"

# A card a worker is actively heartbeating. Must never be reported. Its worker
# pid is this test's own shell, which is definitionally alive.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_active','running and healthy','standard-implementer','running',$now-600,$now-600,'dsaw:1',$$,$now-30,0);"

# A row left in running by a worker that no longer exists (reboot or hard kill).
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_dead','running, worker gone','standard-implementer','running',$now-600,$now-600,'dsaw:1',99998,$now-400,0);"

# A lane at its concurrency cap with work queued behind it: two project-auditor
# cards
# running, one ready, cap 2. Both running workers are this test's own shell.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_sat1','saturated lane a','project-auditor','running',$now-600,$now-600,'dsaw:1',$$,$now-30,0);
INSERT INTO tasks VALUES
  ('t_sat3','saturated lane c','project-auditor','running',$now-600,$now-600,'dsaw:2',$$,$now-30,0);
INSERT INTO tasks VALUES
  ('t_sat2','saturated lane b','project-auditor','ready',$now-600,$now-600,NULL,NULL,$now-30,0);"

# Auto-routed out of the block loop; nothing dispatches triage.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_triage','gave up','project-auditor','triage',$now-600,$now-600,NULL,NULL,$now-600,3);"

# Already-completed work must never surface.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_done','finished long ago','standard-implementer','done',$now-999999,$now-999999,NULL,NULL,$now-999999,0);"

# A lane holding more live workers than its cap allows, with nothing queued
# behind it: the cap guard is not holding.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_over1','over cap a','feature-reviewer','running',$now-600,$now-600,'dsaw:3',$$,$now-30,0);
INSERT INTO tasks VALUES
  ('t_over2','over cap b','feature-reviewer','running',$now-600,$now-600,'dsaw:4',$$,$now-30,0);
INSERT INTO tasks VALUES
  ('t_over3','over cap c','feature-reviewer','running',$now-600,$now-600,'dsaw:5',$$,$now-30,0);"

cat >"$fixture/hermes/config.yaml" <<'YAML'
kanban:
  review_dispatch: true
  max_in_progress: 4
  max_in_progress_per_profile: 2
cron:
  catch_up_missed: true
YAML

echo "▶ kanban board health contract"

run_health() {
  HERMES_ROOT="$fixture/hermes" HERMES_BOARD=testboard \
    HERMES_REPO=/nonexistent-repo "$HEALTH"
}

# --- detection ---------------------------------------------------------------

out="$(run_health)"

grep -q '^READY_NO_WORKER t_stale local-implementer ' <<<"$out" ||
  fail "did not report the stale unclaimed ready card"
pass "reports a stale unclaimed ready card"

grep -q 'age=gt4h hard=yes' <<<"$out" ||
  fail "a 2h-old card should be past the hard threshold"
pass "flags a card past the hard threshold as hard=yes"

grep -q 'hard=no' <<<"$out" && fail "the only stale card here is old; hard=no should not appear"
pass "hard threshold boundary behaves"

grep -q '^DEAD_WORKER t_dead ' <<<"$out" ||
  fail "did not report the running card whose worker pid is gone"
pass "reports a dead worker"

grep -q 't_active' <<<"$out" && fail "reported a live, heartbeating worker as a problem"
pass "leaves a healthy running card alone"

grep -q '^PROFILE_SATURATED project-auditor ready=1 running=2 cap=2' <<<"$out" ||
  fail "did not report the saturated lane, or misread the cap from config.yaml"
pass "reports a saturated lane and parses max_in_progress_per_profile"

grep -q '^TRIAGE_EXHAUSTED t_triage project-auditor blocks=3 ' <<<"$out" ||
  fail "did not report the triage card that exhausted the block loop"
pass "reports a triage card past the block-recurrence limit"

grep -q '^PROFILE_OVER_CAP feature-reviewer running=3 cap=2 ' <<<"$out" ||
  fail "did not report the lane holding more live workers than its cap"
pass "reports a lane over its concurrency cap"

grep -q '^PROFILE_SATURATED feature-reviewer' <<<"$out" &&
  fail "an over-cap lane with nothing queued is not a starvation finding"
pass "does not call an over-cap lane saturated when nothing is queued"

grep -q 't_done' <<<"$out" && fail "reported a completed card"
grep -q 't_sat1' <<<"$out" && fail "reported a lane member that is merely running"
pass "ignores done cards and non-saturated lanes"

# --- the cap must come from config, and the boundary is inclusive ------------
#
# Raising the cap above the running count must silence the finding, or the
# head-coordinator would chase a lane that has headroom.
#
# Output is captured into a variable rather than piped into `grep -q`: under
# `set -o pipefail`, grep's early exit on first match sends SIGPIPE to the
# script, whose failure would then be read as "the assertion did not hold".

sed -i 's/max_in_progress_per_profile: 2/max_in_progress_per_profile: 3/' \
  "$fixture/hermes/config.yaml"
raised="$(run_health)"
grep -q '^PROFILE_SATURATED' <<<"$raised" &&
  fail "still reported saturation after the cap was raised above the running count"
pass "silences the finding once the cap exceeds the running count"

sed -i 's/max_in_progress_per_profile: 3/max_in_progress_per_profile: 2/' \
  "$fixture/hermes/config.yaml"
lowered="$(run_health)"
grep -q '^PROFILE_SATURATED project-auditor ready=1 running=2 cap=2' <<<"$lowered" ||
  fail "cap did not follow the config value"
pass "concurrency cap tracks config.yaml"

# --- output stability: the property the whole cron wiring depends on ---------
#
# Two runs seconds apart must hash identically. Anything time-varying, pid-like
# or path-like breaks this, and the symptom is a head-coordinator woken every
# tick.

first="$(run_health | sha256sum)"
sleep 2
second="$(run_health | sha256sum)"
[[ "$first" == "$second" ]] ||
  fail "output is not byte-stable across runs; the cron monitor would never suppress"
pass "output is byte-stable across runs"

# --- clean board emits nothing ----------------------------------------------
#
# The healthy case has to be genuinely empty, otherwise the head-coordinator is
# woken forever on a board that has nothing wrong with it.

sqlite3 "$DB" "DELETE FROM tasks;"
[[ -z "$(run_health)" ]] || fail "a clean board still produced findings"
pass "a clean board produces no findings"

# --- graceful behaviour on a broken install ---------------------------------

if [[ "$(HERMES_ROOT=/nonexistent HERMES_BOARD=nope "$HEALTH")" != "BOARD_MISSING nope (no kanban.db under /nonexistent)" ]]; then
  fail "did not report a missing board clearly"
fi
pass "reports a missing board instead of failing"

echo "▶ kanban board health: all checks passed"