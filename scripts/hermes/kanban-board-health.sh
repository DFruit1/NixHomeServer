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

# ---------------------------------------------------------------------------
# Per-profile concurrency caps
# ---------------------------------------------------------------------------
# `max_in_progress_per_profile` used to be read as one scalar and applied to
# every lane. That was right for a scalar and wrong the moment the key became a
# `{profile: cap}` map: the scalar reader gets nothing back from a nested map, so
# every lane fell through to the fallback. On a board whose real caps are
# standard-implementer=4, local-implementer=1 and project-auditor=1, three
# healthy standard-implementer workers were reported as an over-cap lane every
# tick while a genuinely capped local-implementer lane was never reported at all.
#
# `kanban.max_in_progress_per_profile` has exactly two shapes, and
# `normalize_per_profile_caps` / `per_profile_cap_for` / `_canonical_cap_profile`
# in hermes_cli/kanban_db_dispatch.py are the contract reproduced here:
#
#   * one int  -> one cap for every lane, held under the `*` key
#   * a map    -> {profile: cap} with an optional fallback for lanes the map does
#                 not name
#
# Lookup order is the lane's own cap, then the wildcard fallback, then the
# conservative default. Map keys are canonicalized the way the dispatcher does
# it: trimmed, lowercased, `default` and `*` folded onto the wildcard, and a name
# that is not a valid profile id dropped -- it could never match a lane, so
# honouring it would silently apply an unrelated lane's cap.
#
# A map entry is only a cap when it is a positive integer written plainly, which
# is exactly the dispatcher's own test (`isinstance(int) and > 0`). A `0` in a
# map is therefore *dropped* and the lane falls through to the wildcard or the
# default -- it is not a cap of zero. A quoted `"4"` is a YAML string, which the
# dispatcher rejects, so it is not a cap here either.
#
# The scalar form is the one deliberate divergence, and it is preserved rather
# than repaired: a scalar `0` still resolves to a cap of 0, exactly as this
# script always did. Making the scalar positive-only would be a cap-policy
# change, not a reporting correction.

declare -A CAP_MAP=()
CAPS_READ=0

# The value every unresolvable cap degrades to: absent, unreadable, malformed or
# unrecognised. It is what a fresh install gets, and it is deliberately the
# conservative one -- a monitor that under-reports a saturated lane is silent,
# and silence is the failure this script exists to catch. Nothing here rewrites
# it to a value that suppresses a finding.
CAP_FALLBACK=2

# Bash arithmetic is signed 64-bit, so a config value that does not fit wraps
# instead of erroring, and a wrapped cap turns `running > cap` into a finding
# about a lane that is actually uncapped. A lane cap is a worker count, so a
# value longer than nine digits is already far past anything a board can reach;
# it is *clamped*, not dropped, because dropping it would fall back to the
# conservative default and report the uncapped lane as an overage -- the same
# false-alarm class this repair removes.
CAP_MAX_DIGITS=9
CAP_MAX=999999999

# A cap as it may safely be held and compared: a plain integer no longer than
# CAP_MAX_DIGITS, with anything larger clamped to CAP_MAX. Callers validate the
# shape first; this only bounds the magnitude.
bound_cap() {
  local value="$1"
  if ((${#value} > CAP_MAX_DIGITS)); then
    printf '%s\n' "$CAP_MAX"
  else
    printf '%s\n' "$value"
  fi
}

# A canonical cap-map key for one key read out of config.yaml, or nothing when
# the key names no lane. Always returns 0: the caller filters on the emitted
# string, and a non-zero status here would abort the report under `set -e`.
canonical_cap_key() {
  local key="$1"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  key="${key%\"}"; key="${key#\"}"
  key="${key%\'}"; key="${key#\'}"
  key="${key#"${key%%[![:space:]]*}"}"
  key="${key%"${key##*[![:space:]]}"}"
  key="${key,,}"
  case "$key" in
    # `default` and `*` are the aliased wildcard the dispatcher folds onto the
    # default key, not lanes.
    default|'*') printf '%s\n' '*' ;;
    # A reserved name passes the id grammar but is rejected by
    # validate_profile_name, so it can never name a lane (profiles.py:275).
    hermes|test|tmp|root|sudo) ;;
    *) [[ "$key" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]] && printf '%s\n' "$key" ;;
  esac
  return 0
}

# Canonicalise an assignee through the same normalisation, so a lane stored as a
# title-cased label still matches a lowercase config key.
canonical_assignee() {
  local name="$1"
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"
  printf '%s\n' "${name,,}"
}

# Read `kanban.max_in_progress_per_profile` from config.yaml into CAP_MAP.
#
# A plain integer on the key's own line is one cap for every lane. Otherwise the
# key's entries are walked: the walk is bounded by the next non-blank line at an
# equal or lower indentation, so a sibling key under `kanban:` can never
# masquerade as an entry of this one. The first child line fixes the entry
# indentation and only lines at exactly that depth are entries -- a line nested
# deeper belongs to an entry's own value and is ignored, which is what keeps
# `unrelated: {standard-implementer: 9}` from becoming a cap for that lane. A
# comment line is skipped wherever it sits, because YAML ignores it and a
# two-space comment between two entries must not end the map. Every entry is
# validated as a plain positive integer before it is stored, and anything that
# does not parse is dropped rather than guessed at.
read_config_caps() {
  [[ "$CAPS_READ" == 1 ]] && return 0
  CAPS_READ=1
  [[ -r "$CONFIG" ]] || return 0

  # The scalar form keeps the historic acceptance of `0`, but only in canonical
  # decimal. A leading-zero spelling is not read here at all: YAML resolves it
  # as an octal int (or as a string, for `08`), and `(( ))` reads it as octal
  # too -- and errors outright on `08`, which would silently turn every
  # comparison false and make the board look healthy. Guessing between those
  # readings is worse than degrading to the documented fallback.
  local scalar=""
  scalar="$(awk '
    /^[^[:space:]#]/ { inblock = ($0 ~ /^kanban:/) ? 1 : 0 }
    inblock && $1 == "max_in_progress_per_profile:" {
      sub(/^[^:]*:[[:space:]]*/, "", $0); gsub(/[[:space:]#].*$/, "", $0); print $0; exit
    }
  ' "$CONFIG")"

  if [[ "$scalar" =~ ^(0|[1-9][0-9]*)$ ]]; then
    CAP_MAP['*']="$(bound_cap "$scalar")"
    return 0
  fi

  local line key value canon
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    [[ "$line" == *:* ]] || continue
    key="${line%%:*}"
    value="${line#*:}"
    canon="$(canonical_cap_key "$key")"
    [[ -n "$canon" ]] || continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%%[[:space:]]#*}"
    # No quote stripping: only a plain integer is a cap, matching the
    # dispatcher's `isinstance(int)` test. `"9"` is a string, not a cap.
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || continue
    CAP_MAP["$canon"]="$(bound_cap "$value")"
  done < <(awk '
    /^[^[:space:]#]/ { inblock = ($0 ~ /^kanban:/) ? 1 : 0; next }
    !inblock { next }
    $1 == "max_in_progress_per_profile:" {
      # Only a key with no value on its own line opens a nested map. `key: 5`
      # and `key: {a: 1}` are the scalar and flow shapes, which this bounded scan
      # does not read as a block map (the latter degrades to the fallback, as
      # documented). A value spelled only as a comment is still "no value".
      rest = $0
      sub(/^[^:]*:/, "", rest)
      sub(/^[[:space:]]+/, "", rest)
      if (rest == "" || rest ~ /^#/) {
        keyind = index($0, $1) - 1; entryind = -1; after = 1
      }
      next
    }
    after {
      if ($0 ~ /^[[:space:]]*#/) { next }
      if ($1 == "") { next }
      thisind = index($0, $1) - 1
      if (thisind <= keyind) { exit }
      if (entryind < 0) { entryind = thisind }
      if (thisind == entryind) { print $0 }
    }
  ' "$CONFIG")
}

# The cap that governs one assignee: its own entry, else the wildcard fallback,
# else the conservative default. Always emits a plain non-negative integer; the
# map only ever holds values validated and bounded on the way in.
cap_for() {
  local assignee="$1" resolved="" canon
  # A no-op after the priming read below (CAPS_READ is inherited as 1), so this
  # costs nothing in the loops and still resolves correctly if it is ever called
  # before the priming line.
  read_config_caps
  canon="$(canonical_assignee "$assignee")"
  if [[ -n "$canon" && -n "${CAP_MAP["$canon"]+set}" ]]; then
    resolved="${CAP_MAP["$canon"]}"
  elif [[ -n "${CAP_MAP['*']+set}" ]]; then
    resolved="${CAP_MAP['*']}"
  else
    resolved="$CAP_FALLBACK"
  fi
  printf '%s\n' "$resolved"
}

# Prime the map in this shell. `cap_for` is called inside `$(...)`, so a read it
# triggered there would populate a subshell-local copy and be thrown away -- the
# config would be re-parsed for every row. Reading it here is what makes "the
# config is read exactly once" true, and this runs on a 30-minute cron tick.
read_config_caps

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
  # Resolved per lane rather than against one global number: that is the whole
  # point. A standard-implementer lane at four workers is healthy while a
  # local-implementer lane at two is not.
  cap="$(cap_for "$assignee")"
  if ((running_n >= cap)); then
    emit "PROFILE_SATURATED $assignee ready=$ready_n running=$running_n cap=$cap"
  fi
done <<<"$saturated_rows"

# A lane holding more live workers than its cap allows. The dispatcher is
# supposed to refuse the spawn that would cross the cap, so this means the
# guard is not holding -- typically because cards were requeued to `ready` by
# the rate-limit path and respawned faster than the running count reflected.
# It matters independently of queueing: several workers sharing one local model
# endpoint is the mechanism behind the "quota wall" rate-limit churn.
#
# The cap does not appear in the query any more. A single integer in WHERE or
# HAVING is the same scalar assumption in a second place, and with one in the
# query a lane whose real cap is 1 was filtered out of the result set before its
# own count was ever compared against it -- the exact case this repair is for.
# The count therefore comes back per assignee and every row is compared against
# that lane's cap, so a cap-1 lane with two workers is caught even when nothing
# is queued behind it.
overcap_rows="$(sql "
  SELECT assignee, COUNT(*)
    FROM tasks
   WHERE status = 'running' AND assignee IS NOT NULL
   GROUP BY assignee
   ORDER BY assignee;")"

while IFS='|' read -r assignee running_n; do
  [[ -n "$assignee" ]] || continue
  cap="$(cap_for "$assignee")"
  ((running_n > cap)) || continue
  emit "PROFILE_OVER_CAP $assignee running=$running_n cap=$cap needs=reduce-inflight"
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