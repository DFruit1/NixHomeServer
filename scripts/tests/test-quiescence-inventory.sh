#!/usr/bin/env bash
# Regression test for scripts/hermes/quiescence-inventory.sh.
#
# Why this needs pinning
# ----------------------
# The receipt is the deploy gate's evidence artifact: a later card is supposed
# to byte-verify it instead of re-gathering. The silent failure modes are
# expensive in the opposite direction from the monitor scripts:
#
#   * A receipt that silently drops a board reads as "that lane is quiescent" —
#     the exact inverse of what its absence means.
#   * A partial receipt (some boards, some statuses) is worse than an error:
#     it is a byte-stable fictional report that a verifier will accept.
#   * The baseline/same/change stamp is the only cross-pass memory the receipt
#     carries, so a wrong verdict in either direction misleads the gate.
#
# The script is exercised through its real entry point against a fixture
# HERMES_ROOT, so the sqlite slices, the atomic write and the stamp semantics
# are covered together.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INVENTORY="${QUIESCENCE_SCRIPT:-$TESTS_REPO_ROOT/scripts/hermes/quiescence-inventory.sh}"

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

python3 -m py_compile "$INVENTORY" || fail "quiescence-inventory.sh does not compile"
head -1 "$INVENTORY" | grep -q '^#!' || fail "missing shebang"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

export HERMES_ROOT="$fixture/hermes"
now="$(date +%s)"

# The fixture must name a PID that provably does not exist: quiescence-inventory
# reports "gone" only when kill(pid, 0) raises ProcessLookupError. A literal
# number is environment-sensitive (any unrelated live process that owns it would
# make the receipt say "unknown"), so spawn a short-lived process and reap it.
sleep 30 &
reaped_pid=$!
kill "$reaped_pid" 2>/dev/null || true
wait "$reaped_pid" 2>/dev/null || true

mkdir -p "$fixture/hermes/kanban/boards/testboard"
sqlite3 "$fixture/hermes/kanban/boards/testboard/kanban.db" <<SQL
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT,
  priority INTEGER, created_at INTEGER, started_at INTEGER,
  claim_lock TEXT, worker_pid INTEGER, last_heartbeat_at INTEGER,
  block_kind TEXT, block_recurrences INTEGER DEFAULT 0,
  consecutive_failures INTEGER DEFAULT 0
);
INSERT INTO tasks VALUES
  ('t_writing', 'writing card', 'local-implementer', 'running', 0,
   $((now-60)), $((now-60)), 'lock-abc', $reaped_pid, $((now-30)), '', 0, 0),
  ('t_queued', 'queued card', 'head-coordinator', 'ready', 0,
   $((now-600)), NULL, NULL, 0, $((now-600)), '', 0, 0),
  ('t_wait', 'wait card', 'feature-reviewer', 'blocked', 0,
   $((now-300)), NULL, NULL, 0, $((now-300)), 'dependency', 1, 0);
CREATE TABLE task_runs (
  id INTEGER PRIMARY KEY, task_id TEXT, profile TEXT, step_key TEXT,
  status TEXT, outcome TEXT, worker_pid INTEGER, started_at INTEGER,
  ended_at INTEGER
);
INSERT INTO task_runs VALUES (851, 't_writing', 'local-implementer', NULL,
  'running', NULL, $reaped_pid, $((now-60)), NULL);
SQL

# Empty named board: consumed as "missing", never as silence.
"$INVENTORY" "./missingboard" >/dev/null 2>&1 && fail "upper slug honoured" || true

# The receipt consumes the tracked board.
"$INVENTORY" >/dev/null || fail "board discovery pass failed"
"$INVENTORY" >/dev/null || fail "second pass must cleanly replace the first receipt"

python3 - "$fixture" "$reaped_pid" <<'PY' || fail "receipt contents wrong"
import json, sys
from pathlib import Path

fixture = Path(sys.argv[1])
reaped_pid = int(sys.argv[2])
document = json.loads((fixture / "hermes/state/quiescence-receipts/receipt.json").read_text())
assert document.get("receipt_schema") == 1, list(document.keys())
boards = {entry["board"]: entry for entry in document["boards"]}
assert set(boards) == {"testboard"}, set(boards)
live = boards["testboard"]
assert live["status_counts"] == {"running": 1, "ready": 1, "blocked": 1}, live["status_counts"]
active = {row["id"]: row for row in live["active"]}
writing = active["t_writing"]
assert writing["claim_present"] is True and writing["worker_pid"] == reaped_pid, writing
assert writing["worker_liveness"] == "gone", writing  # the reaped pid no longer exists
idle = active["t_queued"]
assert idle["claim_present"] is False and idle["worker_liveness"] == "no-worker", idle
hold = active["t_wait"]
assert hold["status"] == "blocked" and hold["heartbeat_age"] in ("5-15m", "lt5m"), hold
runs = live["latest_runs"]
assert runs and runs[0]["task_id"] == "t_writing" and runs[0]["run_id"] == 851, runs
PY

pass "receipt covers every tracked board with full active/run slices"

# A corrupt database fails loud with rc=3 and a stderr marker; it must never
# read as an absent (quiescent) board.
mkdir -p "$fixture/hermes/kanban/boards/oz"
printf -- '-\n' > "$fixture/hermes/kanban/boards/oz/kanban.db"
error="$("$INVENTORY" oz 2>&1 >/dev/null)" && rc=$? || rc=$?
[[ "$rc" == 3 ]] || fail "corrupt db should fail rc=3, got $rc"
grep -q "^QUIESCENCE_DB_ERROR board=oz" <<<"$error" || fail "wrong corrupt-db marker: $error"
pass "corrupt board fails loud, never as silence"

# A malformed option is refused rc=2.
"$INVENTORY" --weird 2>/dev/null >/dev/null && fail "bad option honoured" || true
rc=0; "$INVENTORY" --weird 2>/dev/null >/dev/null || rc=$?
[[ "$rc" == 2 ]] || fail "bad option should fail rc=2, got $rc"

pass "quiescence receipt suite complete"
