#!/usr/bin/env bash
# Park cards whose runs keep hitting a provider quota wall.
#
# Why
# ---
# The dispatcher's respawn guard treats a rate-limited run as neither success
# nor failure. A rate-limited worker is requeued to `ready`, the guard holds it
# for the cooldown, then spawns it again -- forever, by design. The guard's own
# docstring says so: the quota wall "is not the card's" fault, so it "retries
# forever (spaced by the cooldown) until quota returns or a real run
# supersedes it". Nothing in that path can ever converge on its own.
#
# On this machine it did not. Two local-implementer cards each accumulated 23+
# runs in about fifteen hours, virtually every one of them ending
# `rate_limited`, with no attempt ever getting far enough to leave a handoff.
# Two costs, and the second is the expensive one:
#
#   * Every cycle burns provider quota and a worker slot on work that cannot
#     start.
#   * Each requeue mutates the board, so the board-health monitor's output
#     changes, so its hash changes, so the cron monitor cannot suppress the
#     head-coordinator. The head-coordinator woke on a 30-minute cadence to post
#     another comment
#     saying the same thing. Three near-identical comments on t_ffbf4279 in 90
#     minutes is the signature.
#
# So the loop needs a terminating condition, and it needs one that is not an
# agent's judgement, because the loop's own side effect is what keeps the agent
# awake. This script is that condition: after a bounded number of consecutive
# quota-wall attempts with no successful run in between, the card is blocked
# with kind=capability and stops being respawned.
#
# Why blocking is the right terminal state
# ----------------------------------------
# `ready` is the only column the dispatcher claims, so leaving the card there
# guarantees another attempt. `blocked` does not, and it is honest: the card is
# not waiting on a decision, it is waiting on capacity, which is an operator
# action. Blocking with `capability` rather than `needs_input` keeps the two
# apart on the board, so nobody reads a quota wall as a policy question.
#
# Nothing is lost by parking. The worktree, the branch, the partial commits and
# the card body all survive; `hermes kanban unblock` resumes it. Blocking also
# writes a `blocked` row into `task_runs`, and because the streak below counts
# backwards only through `rate_limited` outcomes, that row resets the streak.
# An operator who deliberately unblocks a card therefore grants it a fresh
# budget of attempts rather than having it re-parked after one more try -- and if
# the card genuinely cannot get through even then, hermes's own
# BLOCK_RECURRENCE_LIMIT escalates the second capability block to `triage`,
# where the board-health monitor reports it to the head-coordinator. The ladder
# is
# park, then escalate, so the breaker cannot be looped by unblock-and-retry
# either.
#
# Deliberately conservative
# -------------------------
# Only `ready` rows with no claim lock are candidates, so a live worker is never
# interrupted mid-turn. The streak must be *entirely* rate-limited, so a single
# completed, crashed or blocked run in the window exempts the card -- a card
# making progress is never touched, however many quota walls preceded it.
# In-flight runs (`ended_at IS NULL`) are excluded from the count, since their
# outcome is not yet a fact.
#
# Usage
# -----
#   scripts/hermes/kanban-retry-breaker.sh            # apply (parks cards)
#   scripts/hermes/kanban-retry-breaker.sh --check    # report only, change nothing
#
# It is wired as a hermes cron `--script` in the default profile with
# `--no-agent`, like the durability sync: this is a mechanical circuit breaker,
# and it must not depend on an agent lane being healthy to fire. The reason text
# it posts is what the operator and the head-coordinator read, so it names the
# streak,
# the cause and the exact command to resume.
#
# Environment
# -----------
#   HERMES_ROOT                hermes state dir   (default: ~/.hermes)
#   HERMES_BOARD               board slug         (default: nixhomeserver)
#   RETRY_BREAKER_THRESHOLD    consecutive quota-wall attempts before parking
#                              (default: 6)
#   HERMES_BIN                 hermes executable  (default: resolved on PATH)
#   KANBAN_DB                  override the board database path, for tests

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
HERMES_BOARD="${HERMES_BOARD:-nixhomeserver}"
THRESHOLD="${RETRY_BREAKER_THRESHOLD:-6}"
HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
[[ -n "$HERMES_BIN" ]] || HERMES_BIN="$HOME/.local/bin/hermes"

# `hermes kanban` resolves its own root from HERMES_KANBAN_HOME, which the
# dispatcher shares across profiles by design. Exporting it keeps this script
# pointed at the same board the dispatcher reads, and lets a test drive the real
# CLI against a fixture board.
export HERMES_KANBAN_HOME="$HERMES_ROOT"

DB="${KANBAN_DB:-$HERMES_ROOT/kanban/boards/$HERMES_BOARD/kanban.db}"

check_only=false
[[ "${1:-}" == "--check" ]] && check_only=true

[[ "$THRESHOLD" =~ ^[1-9][0-9]*$ ]] || {
  echo "RETRY_BREAKER_THRESHOLD must be a positive integer, got '$THRESHOLD'" >&2
  exit 2
}

if [[ ! -f "$DB" ]]; then
  echo "BOARD_MISSING $HERMES_BOARD (no kanban.db under $HERMES_ROOT)"
  exit 0
fi

if [[ ! -x "$HERMES_BIN" ]]; then
  # Applying without the CLI would mean writing the board behind hermes's back,
  # which loses the event log and the comment. Fail loudly instead: a breaker
  # that cannot block is not a breaker.
  echo "RETRY_BREAKER_NO_CLI $HERMES_BIN is not executable; cannot park cards" >&2
  exit 3
fi

# The candidate query. `ranked` numbers each card's ended runs newest-first over
# *all* outcomes, so a run with an unknown outcome consumes a rank and breaks the
# streak rather than being invisible to it. `streaked` then keeps only the cards
# whose newest `THRESHOLD` ended runs were every one of them a quota wall.
#
# The task filter is applied last, so the streak is counted over each card's
# whole history and not over the ready subset.
# `cat` rather than `read -d ''`: read returns non-zero at EOF without a
# delimiter, which under `set -e` would abort the script before it inspects
# anything.
candidates_sql="$(cat <<SQL
WITH ranked AS (
  SELECT task_id,
         outcome,
         ROW_NUMBER() OVER (PARTITION BY task_id ORDER BY ended_at DESC, id DESC) AS rank
    FROM task_runs
   WHERE ended_at IS NOT NULL
),
streaked AS (
  SELECT task_id, COUNT(*) AS streak
    FROM ranked
   WHERE rank <= $THRESHOLD
     AND outcome = 'rate_limited'
   GROUP BY task_id
  HAVING COUNT(*) = $THRESHOLD
)
SELECT t.id, COALESCE(t.assignee, ''), s.streak
  FROM tasks t
  JOIN streaked s ON s.task_id = t.id
 WHERE t.status = 'ready'
   AND t.claim_lock IS NULL
 ORDER BY t.id;
SQL
)"

parked=0
would_park=0
while IFS='|' read -r id assignee streak; do
  [[ -n "$id" ]] || continue

  reason="Rate-limit retry breaker: $streak consecutive runs of this card ended 'rate_limited' (provider quota wall) with no successful run in between, so the dispatcher has been respawning it indefinitely. Parking it instead of letting the loop continue. This is a lane capacity condition, not a defect in the card: the worktree, branch and partial commits are intact and nothing is lost. Resume with 'hermes kanban --board $HERMES_BOARD unblock $id' once endpoint capacity returns; each unblock grants a fresh budget of $streak attempts. If this card keeps hitting the wall, pin a working model for it with 'hermes kanban --board $HERMES_BOARD set-model $id <model> --provider <provider>' rather than reassigning it to dodge the quota."

  if [[ "$check_only" == true ]]; then
    echo "RATE_LIMIT_LOOP $id ${assignee:-unassigned} streak=$streak threshold=$THRESHOLD would-park"
    would_park=$((would_park + 1))
    continue
  fi

  # A block is refused if the dispatcher claimed the card in the window between
  # the query and here. That refusal is the correct outcome, not an error: it
  # means the card got a real attempt instead of being parked.
  if "$HERMES_BIN" kanban --board "$HERMES_BOARD" block "$id" --kind capability "$reason" >/dev/null; then
    echo "PARKED $id ${assignee:-unassigned} streak=$streak threshold=$THRESHOLD kind=capability"
    parked=$((parked + 1))
  else
    echo "SKIPPED $id ${assignee:-unassigned} reason=claim-raced threshold=$THRESHOLD" >&2
  fi
done < <(sqlite3 -separator '|' "$DB" "$candidates_sql")

if [[ "$check_only" == true ]]; then
  [[ "$would_park" -eq 0 ]] || echo "RETRY_BREAKER_WOULD_PARK $would_park card(s)"
elif [[ "$parked" -eq 0 ]]; then
  # Only say so when there was a real board to inspect, and keep it to one line so
  # a quiet cron tick stays quiet in the job log.
  echo "RETRY_BREAKER_CLEAR board=$HERMES_BOARD threshold=$THRESHOLD"
fi

exit 0