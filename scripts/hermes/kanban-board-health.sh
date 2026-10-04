#!/usr/bin/env bash
# Report kanban board conditions that need a routing decision, as stable lines.
#
# Why
# ---
# The dispatcher is deliberately conservative: it never invents an assignee and
# it never decides that a card is waiting on a human. Both of those are routing
# judgements, and the only role that owns routing judgements is the
# head-coordinator.
# So a card whose worker lane is broken (dead worker, saturated profile,
# mis-assigned lane) sits in `ready` indefinitely and burns a `stuck:` warning
# in the gateway log while nobody with the authority to fix it wakes up.
#
# This script is the detection half of that gap. It is read-only, cheap, and
# prints one line per finding. The head-coordinator is the decision half; see
# the "Board health" section of profiles/head-coordinator/SOUL.md.
#
# It is wired as a hermes cron `--monitor-script`, which hashes the output
# byte-for-byte and suppresses the agent run while the hash is unchanged. The
# output is therefore sorted and free of timestamps, ages are reported as
# coarse buckets rather than exact seconds, and nothing volatile (pids,
# absolute paths, free disk) may appear in it. A finding that flickers between
# two spellings would wake the head-coordinator on every tick.
#
# Usage
# -----
#   scripts/hermes/kanban-board-health.sh            # human/agent readable report
#
# An empty report means a healthy board, so anything that makes the report
# impossible to produce has to fail loudly instead of printing nothing:
#   0  the board was read and the findings are on stdout (possibly none)
#   2  BOARD_HEALTH_BAD_KNOB: an environment knob is not a non-negative integer
#   3  BOARD_HEALTH_DB_ERROR: the board database would not open, or the schema
#      does not have the columns these detectors read
#   4  BOARD_HEALTH_QUERY_ERROR: a detector's query failed at runtime
#
# Environment
# -----------
#   HERMES_ROOT            hermes state dir   (default: ~/.hermes)
#   HERMES_BOARD           board slug         (default: nixhomeserver)
#   HERMES_REPO            repo to audit for unpushed work (default: auto)
#   BOARD_HEALTH_READY_STALE_SEC   ready+unclaimed before reporting (default 900)
#   BOARD_HEALTH_READY_OLD_SEC     ready at all before reporting hard (default 3600)
#   BOARD_HEALTH_TRIAGE_RECURRENCES  triage blocks before reporting (default 2)

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
READY_STALE_SEC="${BOARD_HEALTH_READY_STALE_SEC:-900}"
READY_OLD_SEC="${BOARD_HEALTH_READY_OLD_SEC:-3600}"
TRIAGE_RECURRENCES="${BOARD_HEALTH_TRIAGE_RECURRENCES:-2}"

DB="$HERMES_ROOT/kanban/boards/$HERMES_BOARD/kanban.db"
CONFIG="$HERMES_ROOT/config.yaml"
NOW="$(date +%s)"

# Every knob below is interpolated straight into SQL, and SQL does not accept a
# blank or a stray quote. Validate them the way the retry breaker validates its
# threshold, and refuse the whole report rather than run a query that is about to
# fail: a report that cannot be produced is not a report of a healthy board.
#
# Positive integers only, matching the breaker. Zero is refused rather than
# honoured because these are suppression thresholds -- a 0 would make every
# `ready` card and every `triage` card a finding on every tick, which is exactly
# the "wakes the head-coordinator forever" failure this script is shaped to avoid.
require_positive_int() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "BOARD_HEALTH_BAD_KNOB $label='$value' (want a positive integer)" >&2
    exit 2
  }
}

require_positive_int BOARD_HEALTH_READY_STALE_SEC "$READY_STALE_SEC"
require_positive_int BOARD_HEALTH_READY_OLD_SEC "$READY_OLD_SEC"
require_positive_int BOARD_HEALTH_TRIAGE_RECURRENCES "$TRIAGE_RECURRENCES"

if [[ ! -f "$DB" ]]; then
  echo "BOARD_MISSING $HERMES_BOARD (no kanban.db under $HERMES_ROOT)"
  exit 0
fi

# Why the schema is probed before it is queried
# -------------------------------------------
# This script is a monitor. hermes suppresses the head-coordinator's run by
# hashing this script's stdout byte-for-byte and skipping the agent while the
# hash is unchanged, so the *absence* of output is read as "nothing has changed",
# and an empty report is indistinguishable from a healthy board.
#
# That is exactly what a broken query produces. Every query below ran inside a
# `while ... done < <(sqlite3 ...)` loop, and a failed process substitution is
# never reported to the caller: the loop body does not run, the loop exits zero,
# and the script exits zero having printed nothing. A renamed column, a missing
# table or a corrupt database therefore produced a byte-stable, empty, entirely
# fictional report -- and byte-stability is the property the cron monitor rewards
# most. The head-coordinator was told the board was clean, every tick, for as
# long as the schema stayed broken.
#
# So the schema is probed first and every result set is captured explicitly. The
# probe names the columns the detectors actually read, so a schema change is
# reported as the schema error it is rather than as an empty finding list.
probe_sql="SELECT id, assignee, status, created_at, started_at, claim_lock,
                  worker_pid, last_heartbeat_at, block_recurrences,
                  block_kind, consecutive_failures
             FROM tasks LIMIT 0;"

if ! probe_err="$(sqlite3 "$DB" "$probe_sql" 2>&1)"; then
  # Marker on stderr, one line, non-zero exit: a cron log grepped for
  # BOARD_HEALTH_ surfaces it, and the monitor's empty stdout cannot be mistaken
  # for a clean board because the job itself failed.
  printf 'BOARD_HEALTH_DB_ERROR board=%s db=%s %s\n' \
    "$HERMES_BOARD" "$DB" "${probe_err//$'\n'/ }" >&2
  exit 3
fi

# Read a scalar nested under the top-level `kanban:` block of config.yaml.
# Deliberately not a YAML parser: hermes owns the config format and this only
# needs two integers, and a missing key must degrade to a default rather than
# fail the report.
kanban_config_scalar() {
  local key="$1" default="$2" value=""
  if [[ -r "$CONFIG" ]]; then
    value="$(awk -v key="$key" '
      /^[^[:space:]#]/ { inblock = ($0 ~ /^kanban:/) ? 1 : 0 }
      inblock && $1 == key":" {
        sub(/^[^:]*:[[:space:]]*/, "", $0); gsub(/[[:space:]#].*$/, "", $0); print $0; exit
      }
    ' "$CONFIG")"
  fi
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s\n' "$value" || printf '%s\n' "$default"
}

MAX_PER_PROFILE="$(kanban_config_scalar max_in_progress_per_profile 2)"

# The cap is compared with `(( ))`, so a non-integer here is arithmetic on the
# empty string rather than an error: every comparison goes false and the
# saturation detectors go quiet, which reads as a healthy board. Unlike the
# environment knobs above, this one comes from a config file this script does not
# own and must not refuse to run over, so degrade to the conservative default.
# The default is 2 because that is what a fresh install gets and the number only
# ever appears in output.
[[ "$MAX_PER_PROFILE" =~ ^[0-9]+$ ]] || {
  echo "board-health: max_in_progress_per_profile '$MAX_PER_PROFILE' is not an integer; using 2" >&2
  MAX_PER_PROFILE=2
}

# Age buckets, not exact ages: exact seconds change every run, which would make
# the monitor hash unstable and wake the head-coordinator on every single tick.
bucket() {
  local secs="$1"
  if   ((secs < 300));  then printf 'lt5m'
  elif ((secs < 900));  then printf '5-15m'
  elif ((secs < 1800)); then printf '15-30m'
  elif ((secs < 3600)); then printf '30-60m'
  elif ((secs < 14400)); then printf '1-4h'
  else printf 'gt4h'
  fi
}

# Coarse age of a card's last sign of life.
age_of() {
  local ts="$1"
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  local d=$((NOW - ts))
  ((d < 0)) && d=0
  bucket "$d"
}

emit() { printf '%s\n' "$*"; }

# Capture a result set before iterating it. A `< <(sqlite3 ...)` loop cannot
# report the query's exit status, and every detector here runs in one, so a
# renamed column silently emptied the whole report (see above). `sql` is a
# wrapper so every capture in this script fails the same loud way.
sql() {
  local out
  if ! out="$(sqlite3 -separator '|' "$DB" "$1")"; then
    printf 'BOARD_HEALTH_QUERY_ERROR board=%s db=%s\n' "$HERMES_BOARD" "$DB" >&2
    exit 4
  fi
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Board findings
# ---------------------------------------------------------------------------

# `ready` cards nobody has claimed. The dispatcher skips a lane it cannot spawn
# into, so these accumulate silently rather than failing loudly.
ready_rows="$(sql "
  SELECT id,
         COALESCE(assignee, ''),
         $NOW - COALESCE(last_heartbeat_at, started_at, created_at) AS idle
    FROM tasks
   WHERE status = 'ready'
     AND claim_lock IS NULL
     AND $NOW - COALESCE(last_heartbeat_at, started_at, created_at) >= $READY_STALE_SEC
   ORDER BY idle DESC, id;")"

while IFS='|' read -r id assignee age; do
  [[ -n "$id" ]] || continue
  if ((age >= READY_OLD_SEC)); then
    emit "READY_NO_WORKER $id ${assignee:-unassigned} age=$(age_of "$age") hard=yes"
  else
    emit "READY_NO_WORKER $id ${assignee:-unassigned} age=$(age_of "$age") hard=no"
  fi
done <<<"$ready_rows"

# `running` cards whose worker process is gone. After a reboot or a hard kill
# the row survives but the pid does not; hermes reaps these itself, so this is
# a prompt to re-dispatch rather than a data-loss alarm.
pid_rows="$(sql "
  SELECT DISTINCT worker_pid FROM tasks
   WHERE status = 'running' AND worker_pid IS NOT NULL ORDER BY worker_pid;")"

while read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  ((pid > 1)) || continue
  kill -0 "$pid" 2>/dev/null && continue
  dead_rows="$(sql "
    SELECT id, COALESCE(assignee, '') FROM tasks
     WHERE status = 'running' AND worker_pid = $pid ORDER BY id;")"
  while IFS='|' read -r id assignee; do
    [[ -n "$id" ]] || continue
    emit "DEAD_WORKER $id ${assignee:-unassigned} needs=re-dispatch"
  done <<<"$dead_rows"
done <<<"$pid_rows"

# A profile at its concurrency cap cannot spawn, so its `ready` cards starve
# behind long-running siblings. This is what turned a human-decision card into
# a five-hour wait: both local-implementer slots were held by cards awaiting an
# owner.
saturated_rows="$(sql "
  SELECT assignee,
         SUM(CASE WHEN status = 'ready'   THEN 1 ELSE 0 END),
         SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END)
    FROM tasks
   WHERE assignee IS NOT NULL AND status IN ('ready', 'running')
   GROUP BY assignee
  HAVING SUM(CASE WHEN status = 'ready' THEN 1 ELSE 0 END) > 0
   ORDER BY assignee;")"

while IFS='|' read -r assignee ready_n running_n; do
  [[ -n "$assignee" ]] || continue
  ((ready_n > 0)) || continue
  if ((running_n >= MAX_PER_PROFILE)); then
    emit "PROFILE_SATURATED $assignee ready=$ready_n running=$running_n cap=$MAX_PER_PROFILE"
  fi
done <<<"$saturated_rows"

# A lane holding more live workers than its cap allows. The dispatcher is
# supposed to refuse the spawn that would cross the cap, so this means the
# guard is not holding -- typically because cards were requeued to `ready` by
# the rate-limit path and respawned faster than the running count reflected.
# It matters independently of queueing: several workers sharing one local model
# endpoint is the mechanism behind the "quota wall" rate-limit churn.
overcap_rows="$(sql "
  SELECT assignee, COUNT(*)
    FROM tasks
   WHERE status = 'running' AND assignee IS NOT NULL
   GROUP BY assignee
  HAVING COUNT(*) > $MAX_PER_PROFILE
   ORDER BY assignee;")"

while IFS='|' read -r assignee running_n; do
  [[ -n "$assignee" ]] || continue
  ((running_n > MAX_PER_PROFILE)) || continue
  emit "PROFILE_OVER_CAP $assignee running=$running_n cap=$MAX_PER_PROFILE needs=reduce-inflight"
done <<<"$overcap_rows"

# Cards the block-loop detector gave up on. `block_recurrences` hits the limit
# and the card is auto-routed to triage, where nothing dispatches it. Only the
# head-coordinator can decide whether to re-route, re-scope, or escalate to the
# owner.
triage_rows="$(sql "
  SELECT id, COALESCE(assignee, ''), COALESCE(block_recurrences, 0)
    FROM tasks
   WHERE status = 'triage'
   ORDER BY id;")"

while IFS='|' read -r id assignee recurs; do
  [[ -n "$id" ]] || continue
  ((recurs >= TRIAGE_RECURRENCES)) || continue
  emit "TRIAGE_EXHAUSTED $id ${assignee:-unassigned} blocks=$recurs needs=head-coordinator-or-owner"
done <<<"$triage_rows"

# A worker-lane card the dispatcher gave up on, blocked, and nobody has looked
# at since. This is the detector that was missing.
#
# On this board it cost an entire feature chain. `t_bed911e9` (the Qwen/llama.cpp
# office-tools bridge) burned two runs into the iteration ceiling, was recorded
# `gave_up`, and landed in `blocked` with `block_kind` empty -- a worker failure,
# not a question and not a quota wall. Five cards sat in `dependency_wait`
# behind it. Nothing surfaced it: `ready` detectors do not match a blocked row,
# `TRIAGE_EXHAUSTED` needs `triage`, and the retry breaker only parks
# `rate_limited` cards as `capability`. The cron tick that ran nine minutes
# after the give-up logged `no_change (agent run suppressed)`, because an
# unchanged report is exactly what a blind spot looks like from the monitor's
# side. The card was invisible to every lane for the rest of the night.
#
# Two exclusions keep this from stealing another detector's job:
#
#   * `needs_input` is the owner's gate. A card waiting on a human is not
#     undispatchable and must not be reported as though it were.
#   * `capability` is the retry breaker's parking state, already covered by the
#     breaker's own escalation to triage after a second park.
#
# `rate_limited` is excluded as a cause for the same reason: the breaker exists
# precisely to give that class a terminating condition, and a second detector
# reporting it would wake the head-coordinator on the churn the breaker was
# built to stop.
#
# Why consecutive_failures > 0 is the discriminator
# --------------------------------------------------
# `blocked` alone is too broad to act on: it is also how an owner-waiting card
# and a breaker-parked card are spelled. `consecutive_failures` is hermes's own
# unified counter for spawn failure, timeout and crash, and it is only non-zero
# when a worker actually failed. So a card that is blocked *and* carries worker
# failures *and* is not a gate *and* is not breaker-parked is unambiguously a
# lane that lost its worker -- which is precisely the case with no owner.
#
# Why the acknowledgement guard exists
# -----------------------------------
# The report is a cron `--monitor-script`: hermes hashes stdout and skips the
# agent while the hash is unchanged. A detector that kept reporting a card the
# head-coordinator had already ruled on would therefore wake it every 30 minutes
# forever, which is the exact loop that produced three near-identical comments on
# one card in 90 minutes (see kanban-retry-breaker.sh). So a block with a comment
# at or after the blocking event is considered handled and drops out of the
# report. The behaviour is self-limiting: the first tick reports it, the
# coordinator comments, the next tick goes quiet and the hash settles.
#
# Why the report carries no worktree state
# ---------------------------------------
# An earlier draft of this detector also reported whether the worker's worktree
# had uncommitted changes, because a dirty tree is the cheapest possible recovery
# and knowing it up front saves the coordinator a command. It was cut for two
# reasons. Many cards run in the board's shared default_workdir rather than a
# dedicated worktree, so on those `git status` reports the *operator's*
# unrelated work and the flag would flip on any edit anywhere in the tree --
# a hash that changes for reasons that have nothing to do with this card. And
# the coordinator can answer it itself with one command, once, at the moment it
# is already awake. Signal that only exists to be stable belongs in the report;
# judgement belongs in the agent.
failed_block_rows="$(sql "
  SELECT t.id,
         COALESCE(t.assignee, ''),
         COALESCE(t.consecutive_failures, 0),
         COALESCE(r.outcome, ''),
         COALESCE(
           (SELECT MAX(e.created_at) FROM task_events e
             WHERE e.task_id = t.id
               AND e.kind IN ('blocked', 'gave_up', 'crashed', 'timed_out')),
           t.started_at, t.created_at) AS since_ts,
         (SELECT MAX(e.created_at) FROM task_events e
            WHERE e.task_id = t.id
              AND e.kind IN ('blocked', 'gave_up', 'crashed', 'timed_out')) AS block_ts,
         (SELECT MAX(c.created_at) FROM task_comments c
            WHERE c.task_id = t.id) AS comment_ts,
         (SELECT COUNT(*) FROM task_links l WHERE l.parent_id = t.id) AS children
    FROM tasks t
    LEFT JOIN task_runs r ON r.id = (
          SELECT r2.id FROM task_runs r2
           WHERE r2.task_id = t.id AND r2.outcome IS NOT NULL
           ORDER BY r2.id DESC LIMIT 1)
   WHERE t.status = 'blocked'
     AND COALESCE(t.consecutive_failures, 0) > 0
     AND COALESCE(t.block_kind, '') NOT IN ('needs_input', 'capability')
     AND COALESCE(r.outcome, '') NOT IN ('rate_limited', 'blocked')
   ORDER BY since_ts, t.id;")"

while IFS='|' read -r id assignee failures outcome since_ts block_ts comment_ts children; do
  [[ -n "$id" ]] || continue
  # Handled: somebody wrote on the card after it was blocked. Keep the
  # comparison inside the loop because block_ts is optional (a card blocked
  # without a matching terminal event) and an absent bound must not suppress.
  if [[ "$block_ts" =~ ^[0-9]+$ && "$comment_ts" =~ ^[0-9]+$ ]] && ((comment_ts >= block_ts)); then
    continue
  fi
  # The outcome reaches the report through a fixed vocabulary, so an unexpected
  # value degrades to `unknown` instead of putting attacker- or version-shaped
  # text into a byte-hashed line.
  case "$outcome" in
    timed_out) cause="timed_out" ;;
    gave_up)   cause="gave_up" ;;
    crashed)   cause="crashed" ;;
    *)         cause="unknown" ;;
  esac
  emit "WORKER_FAILED_BLOCKED $id ${assignee:-unassigned} cause=$cause failures=$failures age=$(age_of "$((NOW - since_ts))") children=$children needs=rescope-and-redispatch"
done <<<"$failed_block_rows"

# ---------------------------------------------------------------------------
# Durability findings
# ---------------------------------------------------------------------------
# Worktree branches hold the only copy of their commits until they are pushed.
# A branch that exists locally and on origin is fine; a branch whose commits
# exist only in this clone dies with the disk.

repo="${HERMES_REPO:-}"
if [[ -z "$repo" ]]; then
  repo="$(python3 - "$HERMES_ROOT/kanban/boards/$HERMES_BOARD/board.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.load(fh).get("default_workdir") or "")
except Exception:
    print("")
PY
)"
fi

if [[ -n "$repo" ]] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  # Bounded: this runs unattended on a cron tick, and a hung fetch must not
  # hold the report open. A failed fetch just compares against the last known
  # remote refs, which is the safe direction for an "is my work safe" check.
  timeout 60 git -C "$repo" fetch --quiet origin 2>/dev/null || true
  while read -r branch sha; do
    [[ -n "$branch" ]] || continue
    # Count commits reachable from this branch that no remote ref has. This is
    # the exact "would a disk failure lose this?" question, and it gets both
    # cases right without caring whether the branch was ever pushed: a branch
    # still sitting on the base commit has nothing to lose and is skipped,
    # and a branch whose remote counterpart does not exist yet is still
    # reported accurately.
    ahead="$(git -C "$repo" rev-list --count "$sha" --not --remotes 2>/dev/null || printf '?')"
    [[ "$ahead" =~ ^[0-9]+$ ]] || { emit "UNPUSHED_UNKNOWN $branch needs=manual-check"; continue; }
    ((ahead > 0)) || continue
    emit "UNPUSHED $branch commits=$ahead needs=push"
  done < <(git -C "$repo" for-each-ref \
             --format='%(refname:short) %(objectname)' \
             refs/heads/wt refs/heads/master 2>/dev/null | sort)

  # A commit reachable from some other remote branch is safe from disk loss but
  # still invisible to a fresh clone of master. Report the integration branch
  # separately: it is the one a human or a resuming agent actually pulls.
  if git -C "$repo" rev-parse --verify --quiet origin/master >/dev/null 2>&1; then
    ahead="$(git -C "$repo" rev-list --count origin/master..master 2>/dev/null || printf '?')"
    if [[ "$ahead" =~ ^[0-9]+$ ]] && ((ahead > 0)); then
      emit "MASTER_AHEAD commits=$ahead needs=push-master"
    fi
  else
    emit "MASTER_UNTRACKED needs=push-master"
  fi
fi

exit 0