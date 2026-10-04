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

if [[ ! -f "$DB" ]]; then
  echo "BOARD_MISSING $HERMES_BOARD (no kanban.db under $HERMES_ROOT)"
  exit 0
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

# ---------------------------------------------------------------------------
# Board findings
# ---------------------------------------------------------------------------

# `ready` cards nobody has claimed. The dispatcher skips a lane it cannot spawn
# into, so these accumulate silently rather than failing loudly.
while IFS='|' read -r id assignee age; do
  [[ -n "$id" ]] || continue
  if ((age >= READY_OLD_SEC)); then
    emit "READY_NO_WORKER $id ${assignee:-unassigned} age=$(age_of "$age") hard=yes"
  else
    emit "READY_NO_WORKER $id ${assignee:-unassigned} age=$(age_of "$age") hard=no"
  fi
done < <(sqlite3 -separator '|' "$DB" "
  SELECT id,
         COALESCE(assignee, ''),
         $NOW - COALESCE(last_heartbeat_at, started_at, created_at) AS idle
    FROM tasks
   WHERE status = 'ready'
     AND claim_lock IS NULL
     AND $NOW - COALESCE(last_heartbeat_at, started_at, created_at) >= $READY_STALE_SEC
   ORDER BY idle DESC, id;")

# `running` cards whose worker process is gone. After a reboot or a hard kill
# the row survives but the pid does not; hermes reaps these itself, so this is
# a prompt to re-dispatch rather than a data-loss alarm.
while read -r pid; do
  [[ "$pid" =~ ^[0-9]+$ ]] || continue
  ((pid > 1)) || continue
  kill -0 "$pid" 2>/dev/null && continue
  while IFS='|' read -r id assignee; do
    [[ -n "$id" ]] || continue
    emit "DEAD_WORKER $id ${assignee:-unassigned} needs=re-dispatch"
  done < <(sqlite3 -separator '|' "$DB" "
    SELECT id, COALESCE(assignee, '') FROM tasks
     WHERE status = 'running' AND worker_pid = $pid ORDER BY id;")
done < <(sqlite3 "$DB" "
  SELECT DISTINCT worker_pid FROM tasks
   WHERE status = 'running' AND worker_pid IS NOT NULL ORDER BY worker_pid;")

# A profile at its concurrency cap cannot spawn, so its `ready` cards starve
# behind long-running siblings. This is what turned a human-decision card into
# a five-hour wait: both local-implementer slots were held by cards awaiting an
# owner.
while IFS='|' read -r assignee ready_n running_n; do
  [[ -n "$assignee" ]] || continue
  ((ready_n > 0)) || continue
  if ((running_n >= MAX_PER_PROFILE)); then
    emit "PROFILE_SATURATED $assignee ready=$ready_n running=$running_n cap=$MAX_PER_PROFILE"
  fi
done < <(sqlite3 -separator '|' "$DB" "
  SELECT assignee,
         SUM(CASE WHEN status = 'ready'   THEN 1 ELSE 0 END),
         SUM(CASE WHEN status = 'running' THEN 1 ELSE 0 END)
    FROM tasks
   WHERE assignee IS NOT NULL AND status IN ('ready', 'running')
   GROUP BY assignee
   HAVING SUM(CASE WHEN status = 'ready' THEN 1 ELSE 0 END) > 0
   ORDER BY assignee;")

# A lane holding more live workers than its cap allows. The dispatcher is
# supposed to refuse the spawn that would cross the cap, so this means the
# guard is not holding -- typically because cards were requeued to `ready` by
# the rate-limit path and respawned faster than the running count reflected.
# It matters independently of queueing: several workers sharing one local model
# endpoint is the mechanism behind the "quota wall" rate-limit churn.
while IFS='|' read -r assignee running_n; do
  [[ -n "$assignee" ]] || continue
  ((running_n > MAX_PER_PROFILE)) || continue
  emit "PROFILE_OVER_CAP $assignee running=$running_n cap=$MAX_PER_PROFILE needs=reduce-inflight"
done < <(sqlite3 -separator '|' "$DB" "
  SELECT assignee, COUNT(*)
    FROM tasks
   WHERE status = 'running' AND assignee IS NOT NULL
   GROUP BY assignee
   HAVING COUNT(*) > $MAX_PER_PROFILE
   ORDER BY assignee;")

# Cards the block-loop detector gave up on. `block_recurrences` hits the limit
# and the card is auto-routed to triage, where nothing dispatches it. Only the
# head-coordinator can decide whether to re-route, re-scope, or escalate to the
# owner.
while IFS='|' read -r id assignee recurs; do
  [[ -n "$id" ]] || continue
  ((recurs >= TRIAGE_RECURRENCES)) || continue
  emit "TRIAGE_EXHAUSTED $id ${assignee:-unassigned} blocks=$recurs needs=head-coordinator-or-owner"
done < <(sqlite3 -separator '|' "$DB" "
  SELECT id, COALESCE(assignee, ''), COALESCE(block_recurrences, 0)
    FROM tasks
   WHERE status = 'triage'
   ORDER BY id;")

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