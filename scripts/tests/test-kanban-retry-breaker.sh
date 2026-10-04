#!/usr/bin/env bash
# Regression test for scripts/hermes/kanban-retry-breaker.sh.
#
# Why this needs pinning
# ----------------------
# The breaker parks a card by writing to the live board, unattended, on a cron
# tick. Both directions of a mistake are expensive:
#
#   * A false negative. The dispatcher's respawn guard retries a rate-limited
#     card forever by design, so a breaker that stops noticing is the same as no
#     breaker. The loop then runs for as long as the quota wall does, waking the
#     head-coordinator on every board-health hash change.
#   * A false positive. Parking a card that was about to make progress strands
#     real work behind a human, on a board where the operator already has two
#     approval gates waiting.
#
# The dangerous cases are all at the edges of the streak window: a card one
# attempt short of the threshold, a card whose streak contains a single
# completed or crashed run, a card mid-claim, a card whose streak was already
# reset by a block. Each of those is pinned here.
#
# The apply path is exercised through the real `hermes kanban block` CLI against
# a fixture board reached via HERMES_KANBAN_HOME, rather than a stubbed command.
# That is deliberate: the state transition, the kind=capability column value and
# the auto-posted comment are exactly the contract this script depends on, and a
# stub would happily keep passing if hermes changed any of them.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BREAKER="$TESTS_REPO_ROOT/scripts/hermes/kanban-retry-breaker.sh"
HERMES_BIN="${HERMES_BIN:-$(command -v hermes 2>/dev/null || true)}"
[[ -n "$HERMES_BIN" ]] || HERMES_BIN="$HOME/.local/bin/hermes"

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

[[ -x "$BREAKER" ]] || fail "kanban-retry-breaker.sh is not executable"
[[ -x "$HERMES_BIN" ]] || fail "hermes CLI not found (set HERMES_BIN)"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export HERMES_KANBAN_HOME="$fixture/hermes"
mkdir -p "$HERMES_KANBAN_HOME"
"$HERMES_BIN" kanban boards create testboard >/dev/null
DB="$HERMES_KANBAN_HOME/kanban/boards/testboard/kanban.db"
[[ -f "$DB" ]] || fail "fixture board database was not created at $DB"

now="$(date +%s)"

# Create a card through the CLI so the row carries whatever the real schema
# requires, then drive its status directly. Using the CLI for creation keeps the
# fixture honest about NOT NULL columns and defaults.
new_card() {
  "$HERMES_BIN" kanban --board testboard create "$1" --assignee "${2:-local-implementer}" 2>/dev/null |
    grep -oE 't_[0-9a-f]+' | head -1
}

# Append an ended run at an explicit timestamp. Insertion order must be
# chronological, because the breaker orders its window by ended_at.
add_run_at() {
  local id="$1" outcome="$2" ended="$3"
  sqlite3 "$DB" "INSERT INTO task_runs
    (task_id, profile, status, started_at, ended_at, outcome)
    VALUES ('$id','local-implementer','done',$((ended - 10)),$ended,'$outcome');"
}

# A streak of `n` quota-wall runs one second apart, oldest first, the newest
# landing on `last`.
quota_streak_ending_at() {
  local id="$1" n="$2" last="$3" i
  for ((i = n - 1; i >= 0; i--)); do
    add_run_at "$id" rate_limited $((last - i))
  done
}

# A streak in the recent past, for a card with no other run history.
quota_streak() { quota_streak_ending_at "$1" "$2" $((now - 1000)); }

# Newest ended run on a card; the anchor for anything that must sort after an
# existing run.
last_end_of() {
  sqlite3 "$DB" "SELECT COALESCE(MAX(ended_at), 0) FROM task_runs
                  WHERE task_id = '$1' AND ended_at IS NOT NULL;"
}

run_breaker() {
  HERMES_ROOT="$HERMES_KANBAN_HOME" HERMES_BOARD=testboard HERMES_BIN="$HERMES_BIN" \
    "$BREAKER" "$@"
}

status_of() { sqlite3 "$DB" "SELECT status FROM tasks WHERE id = '$1';"; }
kind_of() { sqlite3 "$DB" "SELECT COALESCE(block_kind, '') FROM tasks WHERE id = '$1';"; }

echo "▶ kanban retry breaker contract"

# --- the loop is broken ------------------------------------------------------

loop_card="$(new_card 'quota wall loop')"
quota_streak "$loop_card" 6

out="$(run_breaker --check)"
grep -q "^RATE_LIMIT_LOOP $loop_card local-implementer streak=6 threshold=6 would-park" <<<"$out" ||
  fail "did not report the card with six consecutive quota-wall runs"
pass "reports a card whose every recent run hit the quota wall"

grep -q '^RETRY_BREAKER_WOULD_PARK 1 card' <<<"$out" ||
  fail "--check did not summarise what it would park"
pass "--check reports a would-park summary"

[[ "$(status_of "$loop_card")" == "ready" ]] ||
  fail "--check mutated the board; it must change nothing"
pass "--check changes nothing"

run_breaker >/dev/null
[[ "$(status_of "$loop_card")" == "blocked" ]] ||
  fail "a card in 'ready' with no claim lock was not parked"
pass "parks the card"

[[ "$(kind_of "$loop_card")" == "capability" ]] ||
  fail "parked with the wrong block kind; capacity must stay distinct from a policy question"
pass "parks with kind=capability"

sqlite3 "$DB" "SELECT body FROM task_comments WHERE task_id = '$loop_card';" |
  grep -q 'quota wall' ||
  fail "the parked card has no comment explaining the quota wall"
pass "records the reason as a comment on the card"

# --- idempotence: a second tick must not re-park or re-comment --------------

comments_before="$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_comments WHERE task_id = '$loop_card';")"
out="$(run_breaker)"
grep -q 'PARKED' <<<"$out" && fail "re-parked an already parked card"
comments_after="$(sqlite3 "$DB" "SELECT COUNT(*) FROM task_comments WHERE task_id = '$loop_card';")"
[[ "$comments_before" == "$comments_after" ]] ||
  fail "a quiet tick appended another comment to an already parked card"
pass "a second tick neither re-parks nor re-comments"

# --- one attempt short of the threshold must be left alone ------------------

short_card="$(new_card 'one short')"
quota_streak "$short_card" 5

run_breaker >/dev/null
[[ "$(status_of "$short_card")" == "ready" ]] ||
  fail "parked a card that had not yet reached the threshold"
pass "leaves a card one attempt short of the threshold alone"

# --- a single real run inside the window exempts the card -------------------
#
# This is the false-positive guard that matters most. A card that crashed, or
# blocked, or completed a step since the quota walls started is a card with a
# problem the breaker does not own.

for outcome in completed crashed blocked; do
  mixed_card="$(new_card "mixed $outcome")"
  quota_streak "$mixed_card" 8
  add_run_at "$mixed_card" "$outcome" $((now - 900))   # newest, breaks the streak
  run_breaker >/dev/null
  [[ "$(status_of "$mixed_card")" == "ready" ]] ||
    fail "parked a card whose newest run was '$outcome'; only an unbroken quota wall qualifies"
done
pass "a completed, crashed or blocked run inside the window exempts the card"

# --- progress, however old, is progress -------------------------------------
#
# The streak must be unbroken, not recent. A card that did real work yesterday
# and then hit a wall is still a card worth parking, but a card that finished a
# run in the middle of the window is not -- even if the wall came after it.

progress_card="$(new_card 'progress then wall')"
quota_streak_ending_at "$progress_card" 3 $((now - 1700))
add_run_at "$progress_card" completed $((now - 1600))
quota_streak_ending_at "$progress_card" 3 $((now - 1000))
run_breaker >/dev/null
[[ "$(status_of "$progress_card")" == "ready" ]] ||
  fail "parked a card whose streak was broken in the middle by a completed run"
pass "a completed run anywhere in the window exempts the card"

# --- never interrupt a live worker ------------------------------------------

running_card="$(new_card 'live worker')"
quota_streak "$running_card" 9
sqlite3 "$DB" "UPDATE tasks SET status = 'running', claim_lock = 'dsaw:1', worker_pid = $$ WHERE id = '$running_card';"

run_breaker >/dev/null
[[ "$(status_of "$running_card")" == "running" ]] ||
  fail "parked a card that is currently claimed and running"
pass "leaves a claimed, running card alone"

# Claimed but not running: the dispatcher is mid-claim. Also hands off.
claimed_card="$(new_card 'mid claim')"
quota_streak "$claimed_card" 9
sqlite3 "$DB" "UPDATE tasks SET claim_lock = 'dsaw:1' WHERE id = '$claimed_card';"

run_breaker >/dev/null
[[ "$(status_of "$claimed_card")" == "ready" ]] ||
  fail "parked a card holding a claim lock"
pass "leaves a card holding a claim lock alone"

# --- in-flight runs are not yet facts ---------------------------------------
#
# A run with no ended_at is still going. It must neither extend the streak (it
# has not hit a wall yet) nor break it (it has not succeeded yet).

inflight_card="$(new_card 'in flight')"
quota_streak "$inflight_card" 6
sqlite3 "$DB" "INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome)
  VALUES ('$inflight_card','local-implementer','running',$now,NULL,NULL);"

run_breaker >/dev/null
[[ "$(status_of "$inflight_card")" == "blocked" ]] ||
  fail "an unfinished run broke the streak and spared a card that should have been parked"
pass "an in-flight run neither extends nor breaks the streak"

# An in-flight run on top of a real streak must not stop the breaker.
overlap_card="$(new_card 'streak plus in flight')"
quota_streak "$overlap_card" 6
sqlite3 "$DB" "INSERT INTO task_runs (task_id, profile, status, started_at, ended_at, outcome)
  VALUES ('$overlap_card','local-implementer','running',$now,NULL,NULL);"
run_breaker >/dev/null
[[ "$(status_of "$overlap_card")" == "blocked" ]] ||
  fail "an in-flight run shielded a card from the breaker"
pass "an in-flight run does not shield a card from the breaker"

# --- a block resets the budget ----------------------------------------------
#
# The breaker writes a 'blocked' run row, and the streak counts backwards only
# through rate-limited outcomes. That is what makes an operator's unblock grant
# a fresh budget instead of an instant re-park.

reset_card="$(new_card 'unblock gets a fresh budget')"
quota_streak "$reset_card" 6
run_breaker >/dev/null
[[ "$(status_of "$reset_card")" == "blocked" ]] || fail "setup: expected the card parked"

"$HERMES_BIN" kanban --board testboard unblock "$reset_card" >/dev/null

# Anchor on whatever the block and the unblock each wrote, so the post-unblock
# attempts genuinely sort after them. Timestamps guessed relative to `date +%s`
# would sit behind the breaker's own 'blocked' row and silently pass without
# ever exercising the reset.
anchor="$(last_end_of "$reset_card")"
add_run_at "$reset_card" rate_limited $((anchor + 1))   # one fresh attempt, then the wall
run_breaker >/dev/null
[[ "$(status_of "$reset_card")" == "ready" ]] ||
  fail "a single post-unblock attempt was enough to re-park the card"
pass "one attempt after an unblock does not re-park the card"

quota_streak_ending_at "$reset_card" 6 $((anchor + 7))
run_breaker >/dev/null
# Not 'blocked': this is the second capability block of this card's life, so
# hermes's own BLOCK_RECURRENCE_LIMIT escalates it to triage instead. That is
# the ladder working -- park, then escalate -- and it means the breaker cannot
# itself be looped by unblock-and-retry.
[[ "$(status_of "$reset_card")" == "triage" ]] ||
  fail "a second capability block did not escalate to triage; got '$(status_of "$reset_card")'"
pass "a second breaker intervention escalates the card to triage"

# --- the threshold is configurable ------------------------------------------

wide_card="$(new_card 'wide threshold')"
quota_streak "$wide_card" 6
RETRY_BREAKER_THRESHOLD=3 run_breaker >/dev/null
[[ "$(status_of "$wide_card")" == "blocked" ]] ||
  fail "RETRY_BREAKER_THRESHOLD=3 did not lower the bar"
pass "the threshold is configurable"

narrow_card="$(new_card 'narrow threshold')"
quota_streak "$narrow_card" 3
RETRY_BREAKER_THRESHOLD=6 run_breaker >/dev/null
[[ "$(status_of "$narrow_card")" == "ready" ]] ||
  fail "RETRY_BREAKER_THRESHOLD=6 did not raise the bar"
pass "a raised threshold spares a shorter streak"

if RETRY_BREAKER_THRESHOLD=0 run_breaker >/dev/null 2>&1; then
  fail "a zero threshold was accepted; it must fail rather than park everything"
fi
pass "a nonsensical threshold fails instead of parking everything"

# --- cards the breaker has no business touching ---------------------------

done_card="$(new_card 'finished')"
quota_streak "$done_card" 9
sqlite3 "$DB" "UPDATE tasks SET status = 'done' WHERE id = '$done_card';"
triage_card="$(new_card 'in triage')"
quota_streak "$triage_card" 9
sqlite3 "$DB" "UPDATE tasks SET status = 'triage' WHERE id = '$triage_card';"

out="$(run_breaker --check)"
grep -qE "(done_card|triage_card)" <<<"$out" &&
  fail "offered to park a card that is not in 'ready'"
pass "ignores cards that are not ready"

# --- clean board ------------------------------------------------------------

sqlite3 "$DB" "DELETE FROM task_runs; DELETE FROM tasks;"
out="$(run_breaker)"
grep -q '^RETRY_BREAKER_CLEAR ' <<<"$out" ||
  fail "a board with no quota-wall loop did not report clear"
pass "reports clear on a healthy board"

# --- graceful behaviour on a broken install --------------------------------

if [[ "$(HERMES_ROOT=/nonexistent HERMES_BOARD=nope "$BREAKER" 2>/dev/null)" != \
  "BOARD_MISSING nope (no kanban.db under /nonexistent)" ]]; then
  fail "did not report a missing board clearly"
fi
pass "reports a missing board instead of failing"

# A breaker that cannot reach the CLI must refuse loudly rather than appear to
# have run: silently doing nothing is indistinguishable from a board with no loop.
missing_cli="$(mktemp -d)"
trap 'rm -rf "$fixture" "$missing_cli"' EXIT
sqlite3 "$DB" "INSERT INTO tasks (id,title,assignee,status,created_at)
  VALUES ('t_nocli','no cli','local-implementer','ready',$now);"
quota_streak t_nocli 6
if HERMES_BIN="$missing_cli/hermes" run_breaker >/dev/null 2>&1; then
  fail "exited 0 with no hermes CLI available; it cannot have parked anything"
fi
pass "refuses loudly when the hermes CLI is unavailable"

echo "▶ kanban retry breaker: all checks passed"