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
# Every finding is scoped to $HERMES_BOARD except OWNER_COMMENT_UNACTED,
# CAPABILITY_OWNER_INPUT, MIRROR_STALE and INSTRUCTION_DRIFT, which enumerate
# every board or the whole hermes home: an owner-answered gate, an
# owner-sourced capability hold, a board whose durability mirror has gone stale
# and installed prompts that lag tracked source can sit anywhere, and the
# head-coordinator must be woken for them whichever board this cron names.
# Their lines carry the board slug, or the drift count, so the coordinator acts
# on the right thing.
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
#   HERMES_REPO            repo to audit for unpushed work and to resolve the
#                          installed-instruction check (default: auto, from the
#                          board's `default_workdir`)
#   BOARD_HEALTH_READY_STALE_SEC   ready+unclaimed before reporting (default 900)
#   BOARD_HEALTH_READY_OLD_SEC     ready at all before reporting hard (default 3600)
#   BOARD_HEALTH_TRIAGE_RECURRENCES  triage blocks before reporting (default 2)
#   BOARD_HEALTH_MIRROR_STALE_SEC   board mirror age before reporting (default 3600)
#   BOARD_HEALTH_OWNER_AUTHORS     comment authors treated as the owner speaking
#                                  on a card (default: owner,desktop,user)
#   BOARD_HEALTH_UNMERGED_TOP_N    named unmerged-accepted branches before the
#                                  count line takes over (default 6)
#   BOARD_HEALTH_CLASSIFICATION_TOP_N  named classification findings before
#                                  the count line takes over (default 4)

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
READY_STALE_SEC="${BOARD_HEALTH_READY_STALE_SEC:-900}"
READY_OLD_SEC="${BOARD_HEALTH_READY_OLD_SEC:-3600}"
TRIAGE_RECURRENCES="${BOARD_HEALTH_TRIAGE_RECURRENCES:-2}"
MIRROR_STALE_SEC="${BOARD_HEALTH_MIRROR_STALE_SEC:-3600}"
# Per-category finding cap for the list-shaped detectors. The report exists to
# wake the head-coordinator once per material change, and that wake owns one
# bounded turn budget (see hermes-cron-policy.md). Listing every backlog item
# turns the detector into a loop: the wake cannot process the list, the retry
# re-arms, and every tick burns the budget again. The capped name list plus a
# count line keeps the backlog visible without exceeding one wake.
UNMERGED_TOP_N="${BOARD_HEALTH_UNMERGED_TOP_N:-6}"
CLASSIFICATION_TOP_N="${BOARD_HEALTH_CLASSIFICATION_TOP_N:-4}"
# Comment authors that are the owner speaking on a card. The owner writes through
# three clients and the board records each with its own author: the desktop app
# as `desktop`, the owner's own CLI as `user`, and an owner-recorded decision
# marker as `owner`. All three are the owner, and omitting any one hides that
# client's answer from this detector -- recreating the "owner spoke, nobody
# acted" silence the finding exists to break. Agents author their profile slug.
# A comma-separated list so a further owner client can be admitted without a
# code change. Not a positive-integer knob, so it is validated separately.
OWNER_AUTHORS="${BOARD_HEALTH_OWNER_AUTHORS:-owner,desktop,user}"

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
require_positive_int BOARD_HEALTH_MIRROR_STALE_SEC "$MIRROR_STALE_SEC"
require_positive_int BOARD_HEALTH_UNMERGED_TOP_N "$UNMERGED_TOP_N"
require_positive_int BOARD_HEALTH_CLASSIFICATION_TOP_N "$CLASSIFICATION_TOP_N"

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
# Both the scalar spelling and the map key are anchored to an *immediate child*
# of the top-level `kanban:` mapping: the setting is read only at the depth of
# kanban's first child. A key of the same name nested inside some unrelated
# kanban key (`unrelated: {max_in_progress_per_profile: 9}`) is that key's value,
# not this setting, and reading it would apply an unrelated number to every lane.
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
    # A line at the mapping root opens or closes the top-level kanban block.
    /^[^[:space:]#]/ {
      inblock = ($0 ~ /^kanban:/) ? 1 : 0; childind = -1; next
    }
    !inblock { next }
    /^[[:space:]]*#/ { next }
    $1 == "" { next }
    {
      thisind = index($0, $1) - 1
      # The first child of kanban fixes the depth of an immediate-child setting.
      if (childind < 0) { childind = thisind }
      # A same-named key nested inside an unrelated kanban key is that key value,
      # not this setting; reading it would lift the cap for the whole board.
      if (thisind != childind) { next }
      if ($1 != "max_in_progress_per_profile:") { next }
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
    # Strip an inline comment before trimming. A plain YAML scalar ends at a `#`
    # that follows whitespace, and `standard-implementer: 4  # note` has more
    # than one space before the comment: trimming first leaves the earlier spaces
    # behind as `4 `, which then fails the integer test and drops a valid cap to
    # the fallback. Strip the comment, then trim whatever is left.
    value="${value%%[[:space:]]#*}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    # No quote stripping: only a plain integer is a cap, matching the
    # dispatcher's `isinstance(int)` test. `"9"` is a string, not a cap.
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || continue
    CAP_MAP["$canon"]="$(bound_cap "$value")"
  done < <(awk '
    # A line at the mapping root opens or closes the top-level kanban block.
    /^[^[:space:]#]/ {
      inblock = ($0 ~ /^kanban:/) ? 1 : 0; childind = -1; next
    }
    !inblock { next }
    /^[[:space:]]*#/ { next }
    $1 == "" { next }
    {
      thisind = index($0, $1) - 1
      if (childind < 0) { childind = thisind }
      if (after) {
        # Entries are the immediate children of the setting key, and the map
        # ends at the first line indented no deeper than that key.
        if (thisind <= keyind) { exit }
        if (entryind < 0) { entryind = thisind }
        if (thisind == entryind) { print $0 }
        next
      }
      # Only an immediate child of kanban is this setting. A same-named key
      # nested inside an unrelated kanban key is that key value, not a cap map.
      if (thisind != childind) { next }
      if ($1 != "max_in_progress_per_profile:") { next }
      # Only a key with no value on its own line opens a nested map. `key: 5`
      # and `key: {a: 1}` are the scalar and flow shapes, which this bounded scan
      # does not read as a block map (the latter degrades to the fallback, as
      # documented). A value spelled only as a comment is still "no value".
      rest = $0
      sub(/^[^:]*:/, "", rest)
      sub(/^[[:space:]]+/, "", rest)
      if (rest == "" || rest ~ /^#/) {
        keyind = thisind; entryind = -1; after = 1
      }
      next
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
  local age="$1"
  [[ "$age" =~ ^[0-9]+$ ]] || { printf 'unknown'; return; }
  bucket "$age"
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

# The repository this board is worked in: HERMES_REPO when set, else the
# board's recorded `default_workdir`. Two detectors need it -- the durability
# audit and the installed-instruction check -- so it is resolved once here
# rather than once per detector, so they can never disagree about which
# checkout is authoritative. Always returns 0 and may print an empty string:
# a board with no recorded workdir is normal, and the callers skip.
board_repo() {
  if [[ -n "${HERMES_REPO:-}" ]]; then
    printf '%s' "$HERMES_REPO"
    return 0
  fi
  python3 - "$HERMES_ROOT/kanban/boards/$HERMES_BOARD/board.json" <<'PY' 2>/dev/null || true
import json, sys
try:
    with open(sys.argv[1]) as fh:
        print(json.load(fh).get("default_workdir") or "")
except Exception:
    print("")
PY
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
# Owner comment awaiting a coordinator decision (EVERY board)
# ---------------------------------------------------------------------------
# A gate card is blocked on the owner; the owner answers by commenting on the
# card (the desktop app authors those comments `desktop`). A comment does not
# change a card's status, so an answered gate stays `blocked` and nothing
# dispatches it -- the answer is recorded on the board and then sits there. This
# detector is the wake-up for that gap: it fires when the *latest* comment on a
# blocked card is the owner's, which is exactly "the owner spoke last and no
# agent has responded".
#
# It is deliberately board-agnostic, unlike every other finding here. A gate can
# be answered on any board, and the head-coordinator must be woken for it
# whichever board this cron names, so the detector enumerates every board's DB
# and names the board on each line. Every other detector stays scoped to
# $HERMES_BOARD, whose policy the cron prompt carries; only this one is
# cross-board, so its line carries the board the coordinator must act on.
#
# It is self-clearing, which the monitor requires: the head-coordinator reads the
# owner's comment, records its reading (its own comment becomes the latest), and
# unblocks when the answer resolves the gate. Either action makes the latest
# author non-owner, so the finding drops out on the next tick and the hash
# settles. The unblock itself still obeys every existing rule -- an owner comment
# is a decision, not authority to release a rejected change, an absent
# capability, or a question the comment does not answer.
shopt -s nullglob
for owner_db in "$HERMES_ROOT"/kanban/boards/*/kanban.db; do
  [[ -f "$owner_db" ]] || continue
  owner_board="$(basename "$(dirname "$owner_db")")"
  case "$owner_board" in
    _*|.*) continue ;;
  esac
  if ! owner_rows="$(sqlite3 -separator '|' "$owner_db" "
        SELECT t.id,
               COALESCE(t.assignee, ''),
               COALESCE(t.block_kind, ''),
               COALESCE((SELECT c.author FROM task_comments c
                          WHERE c.task_id = t.id
                          ORDER BY c.created_at DESC, c.id DESC LIMIT 1), ''),
               COALESCE((SELECT MAX(c.created_at) FROM task_comments c
                          WHERE c.task_id = t.id), t.created_at)
          FROM tasks t
         WHERE t.status = 'blocked'
         ORDER BY 5, t.id;" 2>/dev/null)"; then
    # A board that will not answer must not silently drop out of a byte-hashed
    # report: emit a stable marker line so the gap is visible rather than absent.
    emit "OWNER_COMMENT_SCAN_UNAVAILABLE $owner_board"
    continue
  fi
  while IFS='|' read -r id assignee block_kind last_author comment_ts; do
    [[ -n "$id" ]] || continue
    [[ -n "$last_author" ]] || continue
    case ",${OWNER_AUTHORS}," in
      *",${last_author},"*) ;;
      *) continue ;;
    esac
    emit "OWNER_COMMENT_UNACTED $owner_board $id ${assignee:-unassigned} block=${block_kind:-none} age=$(age_of "$((NOW - comment_ts))") needs=read-comment-and-decide"
  done <<<"$owner_rows"
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# Capability hold that names no input supplier (EVERY board)
# ---------------------------------------------------------------------------
# The retry breaker parks quota-walled cards with kind=capability, and the same
# kind is the tempting place to park anything that feels technical. That is how
# four genuinely owner-sourced gaps -- a missing installed-identity binding, a
# missing interface description, and a custody release only the source owner
# could publish -- sat parked as `capability` and were never surfaced.
#
# The instruction rule requires every capability hold to name the supplier of
# its missing input in the block reason:
#     Input supplier: owner | agent | external-source-owner(<who>) | model/provider
# So a capability card whose recorded reason carries no `Input supplier:` line is
# either a quota park that predates the convention or an owner ask parked as
# technical. Either way the coordinator must look: classify the supplier, and
# when it is the owner, author a gate instead of leaving it parked. The retry
# breaker writes `Input supplier: model/provider` into its own reason, so a
# correctly classified quota park is never reported here.
#
# Cross-board for the same reason as the owner-comment detector: these holds sit
# on nixhomeserver and pcops alike, and the coordinator must be woken whichever
# board this cron names. Self-clearing on classification: the finding is emitted
# only while the reason carries no `Input supplier:` line, so adding it, or
# reclassifying the card away from `capability`, drops the line on the next tick.
#
# The line carries no age bucket on purpose. An age that advances would change
# the byte-hashed output as the bucket rolls over and wake the coordinator again
# and again on a card it has already been shown. A time-stable line means the
# monitor wakes it once, and stays quiet until the card is actually classified.
shopt -s nullglob
for cap_db in "$HERMES_ROOT"/kanban/boards/*/kanban.db; do
  [[ -f "$cap_db" ]] || continue
  cap_board="$(basename "$(dirname "$cap_db")")"
  case "$cap_board" in
    _*|.*) continue ;;
  esac
  if ! cap_rows="$(sqlite3 -separator '|' "$cap_db" "
        SELECT t.id,
               COALESCE(t.assignee, ''),
               CASE WHEN instr(COALESCE((SELECT e.payload FROM task_events e
                                           WHERE e.task_id = t.id AND e.kind = 'blocked'
                                           ORDER BY e.created_at DESC, e.id DESC LIMIT 1), ''),
                               'Input supplier:') > 0 THEN 1 ELSE 0 END
          FROM tasks t
         WHERE t.status = 'blocked'
           AND COALESCE(t.block_kind, '') = 'capability'
         ORDER BY t.id;" 2>/dev/null)"; then
    # A board that will not answer must not drop silently out of a byte-hashed
    # report: emit a stable marker so the gap is visible rather than absent.
    emit "CAPABILITY_SCAN_UNAVAILABLE $cap_board"
    continue
  fi
  while IFS='|' read -r id assignee has_supplier; do
    [[ -n "$id" ]] || continue
    # A hold that names its supplier is classified; leave it alone.
    [[ "$has_supplier" == 0 ]] || continue
    emit "CAPABILITY_OWNER_INPUT $cap_board $id ${assignee:-unassigned} needs=classify-supplier-or-owner-ask"
  done <<<"$cap_rows"
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# Classification audit (EVERY board)
# ---------------------------------------------------------------------------
# Run the periodic classification audit and emit one line per finding.
# Misclassified blocks route cards to the wrong queue and stall work that
# could proceed. This detector surfaces them for the coordinator.
#
# Findings (the audit's 3-line groups, not raw lines) are capped at
# CLASSIFICATION_TOP_N with one additional= counter, like the unmerged list:
# a finding flood must stay triageable inside the coordinator wake's turn
# budget instead of re-arming the budget-exhaustion retry it would otherwise
# cause. The audit script itself is unchanged and always runs.
classification_audit="$HERMES_ROOT/scripts/kanban-classification-audit.py"
if [[ -f "$classification_audit" ]]; then
  classification_emitted=0
  classification_excess=0
  audit_text="$(python3 "$classification_audit" 2>/dev/null || true)"
  skipping_finding=false
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    # A finding group starts at the `  [board] task` line; its detail lines
    # belong to the same finding and follow its fate.
    if [[ "$line" == "  ["* ]]; then
      if ((classification_emitted < CLASSIFICATION_TOP_N)); then
        classification_emitted=$((classification_emitted + 1))
        skipping_finding=false
      else
        classification_excess=$((classification_excess + 1))
        skipping_finding=true
      fi
    fi
    [[ "$skipping_finding" == true ]] && continue
    emit "CLASSIFICATION_AUDIT $line"
  done <<<"$audit_text"
  ((classification_excess > 0)) && emit "CLASSIFICATION_AUDIT_EXCESS additional=$classification_excess needs=resolve-and-recheck"
fi

# ---------------------------------------------------------------------------
# Durability findings
# ---------------------------------------------------------------------------
# Worktree branches hold the only copy of their commits until they are pushed.
# A branch that exists locally and on origin is fine; a branch whose commits
# exist only in this clone dies with the disk.

repo="$(board_repo)"

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

# ---------------------------------------------------------------------------
# Completed accepted work left unmerged (content, not durability)
# ---------------------------------------------------------------------------
# A `done` or `archived` card is the board's own record that the work passed
# the required review. A card branch under refs/heads/wt whose commits are
# still not on master is work the review accepted but nothing integrated: it
# lingers in the worktree and in the durability mirror only, and nothing
# deploys from either, so the acceptance quietly decays. The durability
# detectors above already keep that work disk-safe; this one keeps the
# *merge-back cadence* honest, so accepted work reaches master promptly.
#
# Reads only, never merges: the decision stays with the head-coordinator,
# including the choice to dispose (disposition already consumed elsewhere).
# Patch-equivalent commits -- applied under another shape by a composition
# merge -- count as integrated, so a branch whose every commit is a duplicate
# does not flicker: git marks it '-' and the count drops to zero.

if [[ -n "$repo" ]] && git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  # A board whose schema does not track branches has nothing for this detector
  # to read; skip rather than fail the whole report. Probed with plain sqlite3:
  # `sql` treats any query failure as fatal, and an old schema is a normal
  # state, not a report gap.
  if sqlite3 "$DB" "SELECT branch_name, id FROM tasks LIMIT 0;" >/dev/null 2>&1; then
  if ! rows="$(sql "
    SELECT branch_name, MIN(id) FROM tasks
     WHERE status IN ('done','archived') AND branch_name LIKE 'wt/%'
     GROUP BY branch_name ORDER BY branch_name;")"; then
    printf 'BOARD_HEALTH_QUERY_ERROR board=%s db=%s (unmerged scan)\n' "$HERMES_BOARD" "$DB" >&2
    exit 4
  fi
  # The coordinator's merge-back disposition is a comment on the owning card,
  # so the audit trail and this detector read the same fact: the branch may
  # stay unmerged, but a recorded disposition stops the finding, exactly as a
  # merge would. Other authors do not carry the marker.
  #
  # The per-item list is capped at UNMERGED_TOP_N (default 6) with one
  # additional= counter, the same shape as the other bounded detectors. A
  # backlog cannot fit in the coordinator wake's turn budget when the report
  # lists all of it: the 2026-10-21/22 loop had every tick re-detect a backlog
  # its one agent pass could not process, so the wake exhausted its budget,
  # left a pending retry, and re-burned itself on the next tick. The report
  # must stay small enough to triage in one wake; the count line keeps the
  # backlog honest while only the oldest items are named. Progress retires
  # names in order, so the hash changes exactly when a finding actually moves.
  disposed="$(sql "
    SELECT DISTINCT task_id FROM task_comments
     WHERE author = 'head-coordinator' AND body LIKE 'merge-back disposition:%';")" || disposed=""
  emitted_unmerged=0
  excess_unmerged=0
  while IFS='|' read -r branch task_id; do
    [[ -n "$branch" ]] || continue
    case "|$disposed|" in *"|$task_id|"*) continue ;; esac
    sha="$(git -C "$repo" rev-parse --verify --quiet "$branch" 2>/dev/null)" || continue
    ahead="$(git -C "$repo" rev-list --count "$sha" --not master 2>/dev/null)"
    [[ "$ahead" =~ ^[0-9]+$ ]] || { emit "UNMERGED_UNKNOWN $task_id branch=$branch needs=manual-check"; continue; }
    ((ahead > 0)) || continue
    unapplied="$(git -C "$repo" cherry master "$sha" 2>/dev/null | grep -c '^+' || true)"
    [[ "$unapplied" =~ ^[0-9]+$ ]] || { emit "UNMERGED_UNKNOWN $task_id branch=$branch needs=manual-check"; continue; }
    ((unapplied > 0)) || continue
    if ((emitted_unmerged < UNMERGED_TOP_N)); then
      emit "UNMERGED_ACCEPTED_WORK $task_id branch=$branch commits=$unapplied needs=merge-or-dispose"
      emitted_unmerged=$((emitted_unmerged + 1))
    else
      excess_unmerged=$((excess_unmerged + 1))
    fi
  done <<<"$rows"
  ((excess_unmerged > 0)) && emit "UNMERGED_EXCESS additional=$excess_unmerged needs=reduce-backlog"
  fi
fi

# ---------------------------------------------------------------------------
# Durability mirror staleness (EVERY board)
# ---------------------------------------------------------------------------
# The durability-sync cron records the epoch of each board's last successful
# mirror under $HERMES_ROOT/state/durability-sync/<board>.epoch. A mirror that
# has gone stale -- a cron a hermes upgrade dropped, a workstation-to-server
# SSH outage, a failing rotation -- leaves the boards workstation-only, and
# the sync's own failure delivery is local, so nothing wakes anyone. The
# sync's per-tick failures also self-clear from the job log; this line stays
# until a mirror actually succeeds again, so the coordinator sees a
# persistent outage once, and sees it resolved when it clears.
#
# No age bucket on the line, for the same reason as the capability detector:
# an advancing age would re-wake the coordinator at every bucket rollover on
# a card it has already been shown. The line is time-stable and self-clearing
# on the next successful mirror.
shopt -s nullglob
for mirror_db in "$HERMES_ROOT"/kanban/boards/*/kanban.db; do
  [[ -f "$mirror_db" ]] || continue
  mirror_board="$(basename "$(dirname "$mirror_db")")"
  case "$mirror_board" in
    _*|.*) continue ;;
  esac
  mirror_epoch_file="$HERMES_ROOT/state/durability-sync/$mirror_board.epoch"
  mirror_epoch=""
  if [[ -r "$mirror_epoch_file" ]]; then
    mirror_epoch="$(tr -cd '0-9' <"$mirror_epoch_file")"
  fi
  if [[ -z "$mirror_epoch" ]] || ((NOW - mirror_epoch >= MIRROR_STALE_SEC)); then
    emit "MIRROR_STALE $mirror_board needs=verify-durability-sync-cron"
  fi
done
shopt -u nullglob

# ---------------------------------------------------------------------------
# Installed-instruction drift (plan item H8)
# ---------------------------------------------------------------------------
# Installed prompts that lag tracked source are silent by construction: the
# running profile keeps reading the old text, the repository keeps the new
# text, and nothing compares them. Paraphrases have already diverged twice that
# way, and an installer nobody re-ran looks exactly like an installer that had
# nothing to do. `install-instruction-policy.py --check` is that comparison and
# it is read-only (it writes nothing unless the flag is dropped), so board
# health can run it on every tick and report the result.
#
# It runs the *repository* copy from `board_repo`, never an installed copy
# under $HERMES_ROOT/scripts: the installer resolves its tracked source from
# its own location and compares it against $HERMES_ROOT, so an installed copy
# would compare the installed tree with itself and always report clean.
#
# The finding is bounded on purpose. The drift list itself names absolute
# installed paths -- which must not appear in this byte-hashed report -- and it
# changes whenever any single installed file is applied, so echoing it would
# wake the coordinator repeatedly on the same drift. One stable line with the
# number of drifted files is the actionable signal ("the whole fleet" versus
# "one file"); the coordinator runs the check to see which.
#
# Exit codes are load-bearing: 1 with drift lines is drift, and anything else
# (a broken tracked source, an unreadable installed tree, a missing helper or
# interpreter) is the check failing to run and is reported separately rather
# than as drift. The count is also required evidence: the installer returns 1
# only when it printed at least one drift line, so a bare 1 with no parsed line
# means the run died before it could report -- a Python traceback exits 1 too,
# and calling that "drift files=0" would send the coordinator after the wrong
# thing. A missing repository or installer is not a board condition -- boards
# differ in whether they carry this checkout -- so it reports nothing.
instruction_check="$repo/scripts/hermes/install-instruction-policy.py"
if [[ -n "$repo" && -f "$instruction_check" ]]; then
  # Bounded: this runs unattended on a cron tick, and the installer reads and
  # compares the whole installed tree. A hung run must not hold the report open.
  drift_rc=0
  drift_out="$(timeout 60 python3 -B "$instruction_check" --check 2>/dev/null)" || drift_rc=$?
  if ((drift_rc != 0)); then
    drift_files="$(grep -c '^drift: ' <<<"$drift_out" || true)"
    [[ -n "$drift_files" ]] || drift_files=0
    if [[ "$drift_rc" == 1 && "$drift_files" =~ ^[1-9][0-9]*$ ]]; then
      emit "INSTRUCTION_DRIFT files=$drift_files needs=apply-install-instruction-policy"
    else
      emit "INSTRUCTION_DRIFT_UNCHECKED exit=$drift_rc needs=manual-check"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Installed cron-script drift
# ---------------------------------------------------------------------------
#
# INSTRUCTION_DRIFT above covers the instruction installers' outputs, but the
# cron-owned scripts have a second installation path with the same silent-drift
# failure mode: the aging escalator runs ~/.hermes/scripts/kanban-aging-escalation.py,
# refreshed only by a manual `--install-files`, and the owner-alert/one-off
# self-installers behave the same way. Stale wording there directly changes
# dispatch behavior, and nothing compares it. This check hashes every known
# cron-owned installed copy against the checkout's tracked source.
#
# The report is bounded and stable like the rest: one counter, no absolute
# paths. `files=` counts installed copies that exist but differ, so an
# unchanged finding does not wake the coordinator repeatedly; adding, editing
# or deleting a copy changes the count and does. A *missing* installed script
# is not counted here: the cron engine surfaces that itself on every tick (the
# failure-deliver path), and a fresh hermes root legitimately lacks parts of
# this list until their own installers run -- an uninstalled-tree clock must
# not read as drift. And "empty" is a valid state -- a checkout-less board
# reports nothing, like the instruction check.
cron_script_drift_names=(kanban-aging-escalation.py kanban-owner-alerts.py
                         kanban-durability-sync.sh kanban-retry-breaker.sh
                         usage-pace.py)
if [[ -n "$repo" ]]; then
  script_drift_files=0
  for drift_name in "${cron_script_drift_names[@]}"; do
    tracked="$repo/scripts/hermes/$drift_name"
    [[ -f "$tracked" ]] || continue
    installed_hit=false
    for installed in "$HERMES_ROOT/scripts/$drift_name" \
                     "$HERMES_ROOT"/profiles/*/scripts/"$drift_name"; do
      [[ -f "$installed" ]] || continue
      cmp -s "$tracked" "$installed" || installed_hit=true
    done
    [[ "$installed_hit" == true ]] && script_drift_files=$((script_drift_files + 1))
  done
  if ((script_drift_files > 0)); then
    emit "SCRIPT_DRIFT files=$script_drift_files needs=apply-owning-installer"
  fi
fi

exit 0