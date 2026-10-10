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
# The seam for installed copies. The whole suite exercises exactly the script
# this names -- the executable check below makes a typo in the override a loud
# failure rather than a silent fallback to the source copy -- so an installed
# copy is held to the same contract without editing it or rewriting this file.
BOARD_HEALTH_SCRIPT="${BOARD_HEALTH_SCRIPT:-$TESTS_REPO_ROOT/scripts/hermes/kanban-board-health.sh}"
HEALTH="$BOARD_HEALTH_SCRIPT"
export HEALTH

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
  block_recurrences INTEGER DEFAULT 0,
  block_kind TEXT,
  consecutive_failures INTEGER DEFAULT 0
);
CREATE TABLE task_comments (id INTEGER PRIMARY KEY, task_id TEXT, body TEXT, created_at INTEGER);
CREATE TABLE task_events (id INTEGER PRIMARY KEY, task_id TEXT, kind TEXT, created_at INTEGER);
CREATE TABLE task_runs (id INTEGER PRIMARY KEY, task_id TEXT, outcome TEXT, started_at INTEGER, ended_at INTEGER);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT, PRIMARY KEY (parent_id, child_id));
SQL

now="$(date +%s)"

# A card the dispatcher cannot spawn into: ready, unclaimed, stale past the
# threshold. This is the exact shape of the bug that went unnoticed for hours.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_stale','stale ready card','local-implementer','ready',$now-7200,$now-7200,NULL,NULL,$now-7200,0,'',0);"

# A card a worker is actively heartbeating. Must never be reported. Its worker
# pid is this test's own shell, which is definitionally alive.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_active','running and healthy','standard-implementer','running',$now-600,$now-600,'dsaw:1',$$,$now-30,0,'',0);"

# A row left in running by a worker that no longer exists (reboot or hard kill).
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_dead','running, worker gone','standard-implementer','running',$now-600,$now-600,'dsaw:1',99998,$now-400,0,'',0);"

# A lane at its concurrency cap with work queued behind it: two project-auditor
# cards
# running, one ready, cap 2. Both running workers are this test's own shell.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_sat1','saturated lane a','project-auditor','running',$now-600,$now-600,'dsaw:1',$$,$now-30,0,'',0);
INSERT INTO tasks VALUES
  ('t_sat3','saturated lane c','project-auditor','running',$now-600,$now-600,'dsaw:2',$$,$now-30,0,'',0);
INSERT INTO tasks VALUES
  ('t_sat2','saturated lane b','project-auditor','ready',$now-600,$now-600,NULL,NULL,$now-30,0,'',0);"

# Auto-routed out of the block loop; nothing dispatches triage.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_triage','gave up','project-auditor','triage',$now-600,$now-600,NULL,NULL,$now-600,3,'',2);"

# Already-completed work must never surface.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_done','finished long ago','standard-implementer','done',$now-999999,$now-999999,NULL,NULL,$now-999999,0,'',0);"

# A lane holding more live workers than its cap allows, with nothing queued
# behind it: the cap guard is not holding.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_over1','over cap a','feature-reviewer','running',$now-600,$now-600,'dsaw:3',$$,$now-30,0,'',0);
INSERT INTO tasks VALUES
  ('t_over2','over cap b','feature-reviewer','running',$now-600,$now-600,'dsaw:4',$$,$now-30,0,'',0);
INSERT INTO tasks VALUES
  ('t_over3','over cap c','feature-reviewer','running',$now-600,$now-600,'dsaw:5',$$,$now-30,0,'',0);"

# --- the lost worker ----------------------------------------------------------
#
# These cards are all `blocked`, and that is the whole difficulty: the column
# alone means nothing. Only one of them is a worker failure that nobody owns,
# which is the finding that was missing when the Qwen office-tools bridge
# (t_bed911e9) sat blocked and invisible for a night behind two
# iteration-budget timeouts, with five cards waiting on it.
#
# The one that must be reported: gave up, no block_kind, worker failures on
# record, two cards depending on it.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_gaveup','worker ran out of budget','standard-implementer','blocked',$now-7200,$now-7200,NULL,NULL,$now-7200,0,'',2);
INSERT INTO task_runs VALUES (163,'t_gaveup','timed_out',$now-7200,$now-3600);
INSERT INTO task_runs VALUES (164,'t_gaveup','gave_up',$now-3600,$now-1800);
INSERT INTO task_events VALUES (1,'t_gaveup','timed_out',$now-3600);
INSERT INTO task_events VALUES (2,'t_gaveup','gave_up',$now-1800);
INSERT INTO task_links VALUES ('t_gaveup','t_dep1'),('t_gaveup','t_dep2');"

# A crash with no `blocked` event: the cause still has to surface, keyed on the
# run outcome rather than on the presence of an event.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_crash','worker crashed','local-implementer','blocked',$now-3600,$now-3600,NULL,NULL,$now-3600,0,'',1);
INSERT INTO task_runs VALUES (165,'t_crash','crashed',$now-3600,$now-3000);"

# Must NOT be reported: a card waiting on the owner. That is a question, not a
# broken lane, and reporting it would send the coordinator to unblock a gate.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_gate','waiting on the owner','standard-implementer','blocked',$now-3600,$now-3600,NULL,NULL,$now-3600,0,'needs_input',3);
INSERT INTO task_runs VALUES (166,'t_gate','timed_out',$now-3600,$now-3000);
INSERT INTO task_events VALUES (3,'t_gate','blocked',$now-3000);"

# Must NOT be reported: parked by the retry breaker, which owns this class and
# escalates to triage itself after a second park.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_parked','breaker-parked quota wall','local-implementer','blocked',$now-3600,$now-3600,NULL,NULL,$now-3600,1,'capability',4);
INSERT INTO task_runs VALUES (167,'t_parked','rate_limited',$now-3600,$now-3000);
INSERT INTO task_events VALUES (4,'t_parked','blocked',$now-3000);"

# Must NOT be reported: blocked *and* rate-limited, not yet parked. The breaker
# is the component that gives this class a stopping condition, so a second
# detector reporting it would wake the coordinator on exactly the churn the
# breaker exists to end.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_quota','quota wall before the breaker parks it','standard-implementer','blocked',$now-3600,$now-3600,NULL,NULL,$now-3600,0,'',5);
INSERT INTO task_runs VALUES (168,'t_quota','rate_limited',$now-3600,$now-3000);
INSERT INTO task_events VALUES (5,'t_quota','blocked',$now-3000);"

# Must NOT be reported: a blocked worker failure somebody has already ruled on.
# Without this guard the monitor would wake the head-coordinator every 30 minutes
# forever, which is the loop that produced three identical comments on one card
# in 90 minutes.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_handled','already ruled on','standard-implementer','blocked',$now-7200,$now-7200,NULL,NULL,$now-7200,0,'',2);
INSERT INTO task_runs VALUES (169,'t_handled','gave_up',$now-7200,$now-3600);
INSERT INTO task_events VALUES (6,'t_handled','gave_up',$now-3600);
INSERT INTO task_comments VALUES (1,'t_handled','re-scoped, re-dispatching',$now-1800);"

# Must be reported: a comment *before* the block does not count as handling it.
# The decision predates the failure and cannot have been about it.
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_stale_comment','comment predates the block','standard-implementer','blocked',$now-7200,$now-7200,NULL,NULL,$now-7200,0,'',2);
INSERT INTO task_runs VALUES (170,'t_stale_comment','gave_up',$now-7200,$now-3600);
INSERT INTO task_events VALUES (7,'t_stale_comment','gave_up',$now-3600);
INSERT INTO task_comments VALUES (2,'t_stale_comment','starting on this now',$now-7000);"

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

# --- a blocked worker lane that nobody owns ----------------------------------
#
# The finding that was absent when t_bed911e9 stranded the Qwen office-tools
# chain. Each exclusion is pinned separately, because every one of them is a card
# some other rule already owns, and a detector that double-reports sends the
# head-coordinator to unblock a gate or to re-create a breaker loop.

grep -q '^WORKER_FAILED_BLOCKED t_gaveup standard-implementer cause=gave_up failures=2 ' <<<"$out" ||
  fail "did not report the blocked card whose worker ran out of budget"
pass "reports a blocked worker failure with its cause and failure count"

grep -q '^WORKER_FAILED_BLOCKED t_gaveup .*children=2 ' <<<"$out" ||
  fail "did not report how many cards wait behind the blocked one"
pass "reports the blast radius, so the coordinator knows the cost of ignoring it"

grep -q '^WORKER_FAILED_BLOCKED t_crash local-implementer cause=crashed ' <<<"$out" ||
  fail "a crash with no blocked event should still surface, keyed on the run outcome"
pass "reports a crash that left no blocked event behind"

grep -q '^WORKER_FAILED_BLOCKED t_stale_comment ' <<<"$out" ||
  fail "a comment predating the block must not count as having handled it"
pass "reports a block whose only comment predates the failure"

grep -q 't_gate' <<<"$out" && fail "reported a needs_input gate as a broken worker lane"
grep -q 't_parked' <<<"$out" && fail "reported a breaker-parked card, which the breaker owns"
grep -q 't_quota' <<<"$out" && fail "reported a quota wall, which is the breaker's class"
grep -q 't_handled' <<<"$out" &&
  fail "reported a block somebody already ruled on; the monitor would never go quiet"
pass "leaves gates, breaker-parked cards and already-handled blocks alone"

# An outcome outside the known vocabulary must not put arbitrary text into a
# byte-hashed line.
sqlite3 "$DB" "INSERT INTO task_runs VALUES (171,'t_crash','Crashed (pid 12345)',$now-3000,$now-2900);"
weird="$(run_health)"
grep -q '^WORKER_FAILED_BLOCKED t_crash .*cause=unknown ' <<<"$weird" ||
  fail "an unexpected run outcome must degrade to the known vocabulary"
grep -q '12345' <<<"$weird" && fail "leaked raw run-outcome text into the report"
pass "degrades an unknown run outcome instead of leaking it"
sqlite3 "$DB" "DELETE FROM task_runs WHERE id=171;"

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

# --- per-profile caps: the repair this suite exists to pin --------------------
#
# `max_in_progress_per_profile` is a map on this board, and the scalar reader
# could not see one. It resolved to nothing, fell back to 2 for every lane, and
# the monitor then reported a healthy four-worker standard-implementer lane as
# over-cap while never reporting the genuinely capped one-at-a-time
# local-implementer lane. Both halves are pinned below, plus every fallback
# shape, so a regression cannot hide behind a config the test never writes.
#
# A fresh, clean board is used per case: the cap belongs to the config, and a
# leftover row from an earlier case would make the count assertions mean
# something they do not.

write_config() { cat >"$fixture/hermes/config.yaml"; }

reset_board() {
  sqlite3 "$DB" "DELETE FROM tasks;"
  sqlite3 "$DB" "DELETE FROM task_runs;"
  sqlite3 "$DB" "DELETE FROM task_events;"
  sqlite3 "$DB" "DELETE FROM task_comments;"
  sqlite3 "$DB" "DELETE FROM task_links;"
}

# One running row for an assignee. `$$` keeps every worker pid alive: a dead pid
# would surface as a DEAD_WORKER finding and make the case about the wrong thing.
add_running() {
  sqlite3 "$DB" "INSERT INTO tasks VALUES
    ('$1','running $2','$2','running',$now-600,$now-600,'dsaw:1',$$,$now-30,0,'',0);"
}
add_ready() {
  sqlite3 "$DB" "INSERT INTO tasks VALUES
    ('$1','ready $2','$2','ready',$now-600,$now-600,NULL,NULL,$now-30,0,'',0);"
}

# case: a map whose standard lane holds cap 4. Three running workers is head
# room, not an alarm -- this is the false positive that started all of this.
write_config <<'YAML'
kanban:
  review_dispatch: true
  max_in_progress_per_profile:
    default: 2
    local-implementer: 1
    standard-implementer: 4
    project-auditor: 1
cron:
  catch_up_missed: true
YAML
reset_board
add_running t_map_std1 standard-implementer
add_running t_map_std2 standard-implementer
add_running t_map_std3 standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED standard-implementer' <<<"$map_out" &&
  fail "three of four standard-implementer workers were reported as saturated"
grep -q '^PROFILE_OVER_CAP standard-implementer' <<<"$map_out" &&
  fail "three of four standard-implementer workers were reported as over cap"
pass "a map lane under its own cap emits neither cap alarm"

# Same lane at exactly its cap with work queued behind it: equality is
# saturation, because the dispatcher will not spend the slot that is taken.
add_running t_map_std4 standard-implementer
add_ready t_map_stdq standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED standard-implementer ready=1 running=4 cap=4' <<<"$map_out" ||
  fail "four of four standard-implementer workers with a queued card is saturation"
pass "reports saturation at the lane's own cap with the resolved cap printed"

# And one past it, with nothing queued: over-cap is independent of queueing.
add_running t_map_std5 standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP standard-implementer running=5 cap=4 ' <<<"$map_out" ||
  fail "five standard-implementer workers must be reported as over cap 4"
pass "reports over-cap past the lane's own cap"

# case: the SQL prefilter. A lane whose cap is 1 with two running workers and
# nothing queued. A scalar `HAVING COUNT(*) > 2` deleted this row before the
# loop ever saw it, so it is the assertion that proves the cutoff is gone.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    default: 2
    local-implementer: 1
YAML
add_running t_map_loc1 local-implementer
add_running t_map_loc2 local-implementer
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP local-implementer running=2 cap=1 ' <<<"$map_out" ||
  fail "two workers in a cap-1 lane must be over cap even with nothing queued"
pass "a cap-1 lane over cap is reported without the global SQL cutoff"

# The same lane with one running and one queued: saturation at 1, not silence.
add_ready t_map_locq local-implementer
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED local-implementer ready=1 running=2 cap=1' <<<"$map_out" ||
  fail "a cap-1 lane with a queued card and two workers must be saturated"
pass "reports saturation in a cap-1 lane"

# case: an assignee the map does not name uses the `default` fallback. The
# default is written different from the hardcoded 2, so a resolver that just
# prints its own constant without reading the config still fails here.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    default: 3
    standard-implementer: 4
YAML
add_running t_map_def1 feature-reviewer
add_running t_map_def2 feature-reviewer
add_running t_map_def3 feature-reviewer
add_running t_map_def4 feature-reviewer
add_ready t_map_defq feature-reviewer
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP feature-reviewer running=4 cap=3 ' <<<"$map_out" ||
  fail "an unlisted lane must use the map default, not the hardcoded fallback"
pass "an assignee absent from the map falls back to its default entry"

# case: a quoted wildcard `*` instead of `default`. Same role, different
# spelling, and the fallback value differs from 2 for the same reason.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    "*": 4
    local-implementer: 1
YAML
add_running t_map_star1 project-auditor
add_running t_map_star2 project-auditor
add_running t_map_star3 project-auditor
add_running t_map_star4 project-auditor
add_ready t_map_starq project-auditor
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP project-auditor running=4 cap=4' <<<"$map_out" &&
  fail "four workers under a quoted wildcard cap of 4 is not over cap"
grep -q '^PROFILE_SATURATED project-auditor ready=1 running=4 cap=4' <<<"$map_out" ||
  fail "a quoted wildcard fallback was not resolved for the unlisted lane"
pass "a quoted wildcard key resolves as the map fallback"

# case: no fallback at all. An unlisted lane then has no cap to resolve and
# keeps the conservative default, which is exactly what this asserts: two
# running workers cross cap 2, and the emitted cap names that 2 rather than any
# number the config might have supplied.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    local-implementer: 1
YAML
add_running t_map_nodef1 feature-reviewer
add_running t_map_nodef2 feature-reviewer
add_running t_map_nodef3 feature-reviewer
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP feature-reviewer running=3 cap=2 ' <<<"$map_out" ||
  fail "a lane with no entry and no default must fall back to 2"
pass "a map entry with no fallback keeps the conservative default"

# case: an unreadable or absent config must not invent a cap for a lane the map
# named, and must not take the whole report down with it.
reset_board
rm -f "$fixture/hermes/config.yaml"
add_running t_map_abs1 standard-implementer
add_running t_map_abs2 standard-implementer
add_running t_map_abs3 standard-implementer
add_ready t_map_absq standard-implementer
sqlite3 "$DB" "INSERT INTO tasks VALUES
  ('t_map_absdead','gone','local-implementer','running',$now-600,$now-600,'dsaw:1',99998,$now-30,0,'',0);"
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED standard-implementer ready=1 running=3 cap=2' <<<"$map_out" ||
  fail "a missing config must fall back to the default cap rather than to the map"
# A cap-config failure must not take the other detectors down with it: this one
# is age-independent, so it cannot be blamed on a threshold that has not elapsed.
grep -q '^DEAD_WORKER t_map_absdead local-implementer needs=re-dispatch' <<<"$map_out" ||
  fail "a missing cap config must not disable the other detectors"
pass "a missing config falls back without disabling the report"

# case: a malformed cap value. The entry is dropped, not half-parsed into a
# number, and the rest of the map still resolves.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    default: two
    standard-implementer: 4
YAML
add_running t_map_broke1 standard-implementer
add_running t_map_broke2 standard-implementer
add_running t_map_broke3 standard-implementer
add_running t_map_broke4 standard-implementer
add_ready t_map_brokeq standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED standard-implementer ready=1 running=4 cap=4' <<<"$map_out" ||
  fail "a valid lane cap must survive a malformed sibling entry"
pass "a malformed cap value is dropped, not trusted"

reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    default: two
YAML
add_running t_map_broke2x standard-implementer
add_running t_map_broke2y standard-implementer
add_ready t_map_broke2q standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED standard-implementer ready=1 running=2 cap=2' <<<"$map_out" ||
  fail "a malformed default must fall back to the conservative default"
pass "a malformed fallback keeps the conservative default"

# case: malformed nesting, where the key carries a value on its own line. That
# is the scalar shape, which applies to every lane rather than to none.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile: 5
YAML
add_running t_map_nest1 feature-reviewer
add_running t_map_nest2 feature-reviewer
add_running t_map_nest3 feature-reviewer
add_running t_map_nest4 feature-reviewer
add_running t_map_nest5 feature-reviewer
add_ready t_map_nestq feature-reviewer
map_out="$(run_health)"
grep -q '^PROFILE_SATURATED feature-reviewer ready=1 running=5 cap=5' <<<"$map_out" ||
  fail "a scalar cap inside a config that otherwise looks nested must still apply"
pass "a scalar cap still applies to every lane"

# case: numeric zero splits by shape, matching the dispatcher rather than an
# intuition about it. In a *map* the dispatcher skips any entry that is not
# `int and > 0` (kanban_db_dispatch.py:2289), so a 0 there is not a cap: it is
# dropped and the lane falls through to the wildcard. Reporting cap=0 would be
# an over-cap alarm for a lane the dispatcher runs at full speed.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    default: 2
    standard-implementer: 0
YAML
add_running t_map_zero1 standard-implementer
add_running t_map_zero2 standard-implementer
add_running t_map_zero3 standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP standard-implementer running=3 cap=0 ' <<<"$map_out" &&
  fail "a map entry of 0 is dropped by the dispatcher, not honoured as cap 0"
grep -q '^PROFILE_OVER_CAP standard-implementer running=3 cap=2 ' <<<"$map_out" ||
  fail "a dropped map entry must fall through to the wildcard fallback"
pass "a map entry of 0 is dropped and falls back, as the dispatcher does"

# A *scalar* zero is the historic behaviour and is deliberately preserved: the
# base script accepted it, and making it positive-only would be a cap-policy
# change rather than this reporting repair.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile: 0
YAML
add_running t_map_scalarzero standard-implementer
map_out="$(run_health)"
grep -q '^PROFILE_OVER_CAP standard-implementer running=1 cap=0 ' <<<"$map_out" ||
  fail "a scalar zero cap must keep its historic meaning"
pass "a scalar zero cap is preserved"

# case: unrelated keys must not masquerade as cap entries. A sibling kanban key
# and a key in another top-level block that both happen to name a profile have
# to leave the lane's cap alone.
reset_board
write_config <<'YAML'
kanban:
  review_dispatch: true
  max_in_progress_per_profile:
    default: 2
  dispatch_stale_timeout_seconds: 5400
cron:
  standard-implementer: 9
other:
  local-implementer: 8
YAML
add_running t_map_key1 standard-implementer
add_running t_map_key2 standard-implementer
add_ready t_map_keyq standard-implementer
map_out="$(run_health)"
grep -q 'cap=9' <<<"$map_out" && fail "a key from another top-level block became a cap"
grep -q 'cap=8' <<<"$map_out" && fail "a key from an unrelated block became a cap"
grep -q '^PROFILE_SATURATED standard-implementer ready=1 running=2 cap=2' <<<"$map_out" ||
  fail "a sibling kanban key was consumed as a cap entry"
pass "unrelated and out-of-block keys do not masquerade as caps"

# case: a reserved profile name is not a lane. It passes the id grammar but
# validate_profile_name rejects it (profiles.py:275), so the dispatcher drops
# the key; keeping it would let a name that can never match a lane impose its
# cap on the wildcard fallback.
reset_board
write_config <<'YAML'
kanban:
  max_in_progress_per_profile:
    default: 3
    root: 1
    sudo: 1
YAML
add_running t_map_res1 feature-reviewer
add_running t_map_res2 feature-reviewer
add_running t_map_res3 feature-reviewer
add_running t_map_res4 feature-reviewer
map_out="$(run_health)"
grep -q 'cap=1' <<<"$map_out" && fail "a reserved name became a cap key"
grep -q '^PROFILE_OVER_CAP feature-reviewer running=4 cap=3 ' <<<"$map_out" ||
  fail "a reserved cap key must be dropped so the wildcard applies"
pass "reserved profile names are dropped rather than used as cap keys"

# --- the installed copy runs the same suite ----------------------------------
#
# The suite is only evidence about the script it exercised. HEALTH is the
# BOARD_HEALTH_SCRIPT seam, and it was resolved to whatever this run named
# before the first fixture ran, so the checks above are exactly the contract of
# that script. This prints which one that was, so the receipt is not ambiguous.
if [[ "$HEALTH" != "$TESTS_REPO_ROOT/scripts/hermes/kanban-board-health.sh" ]]; then
  echo "▶ exercised installed copy: $HEALTH"
  echo "  ✅ every map/scalar check above ran against this file"
else
  echo "  (set BOARD_HEALTH_SCRIPT=<path> to run this suite against an installed"
  echo "   copy of the monitor)"
fi

echo "▶ kanban board health: all checks passed"
