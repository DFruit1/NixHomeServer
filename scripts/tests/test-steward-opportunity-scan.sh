#!/usr/bin/env bash
# Regression test for scripts/hermes/steward-opportunity-scan.py.
#
# Why this needs pinning
# ----------------------
# The scanner is wired as a hermes cron `--monitor-script`: the cron engine
# hashes its stdout byte-for-byte and suppresses the board-steward's run while
# the hash is unchanged. Three failures are silent and expensive:
#
#   * Unstable output. A timestamp or an absolute path changes every run, so the
#     hash changes every run, so the steward is woken every tick forever and
#     learns to ignore the job.
#   * A missed or spurious CANDIDATE. A miss silently starves the
#     local-implementer; a spurious one floods the board with junk cards.
#   * Broken idempotency suppression. A candidate already covered by an open
#     steward-cleanup card must vanish from the output, or the steward refiles
#     it every run.
#
# The scanner is exercised through its real entry point against a synthetic git
# repo and board database, so the git, filesystem and SQL halves are covered
# together.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCAN="${STEWARD_SCAN_SCRIPT:-$TESTS_REPO_ROOT/scripts/hermes/steward-opportunity-scan.py}"

fail() {
  echo "❌ $1" >&2
  exit 1
}

pass() { echo "  ✅ $1"; }

for tool in git sqlite3 python3; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool '$tool' is not installed"
done

[[ -f "$SCAN" ]] || fail "scanner missing: $SCAN"
python3 -c 'import sys; compile(open(sys.argv[1], "rb").read(), sys.argv[1], "exec")' \
  "$SCAN" || fail "scanner does not compile"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

repo="$fixture/repo"
none="$fixture/none.db"
mkdir -p "$repo/scripts"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m init

scan() { STEWARD_REPO="$repo" STEWARD_BOARD_DB="$1" python3 "$SCAN"; }

# 1. A clean repo prints nothing — the healthy, agent-suppressing state.
out="$(scan "$none")"
[[ -z "$out" ]] || fail "expected empty output on a clean repo, got:
$out"
pass "clean repo prints nothing"

# 2. Seeded breakage is detected with stable, path-relative detail.
printf '#!/bin/sh\nif true; then\n  echo hi\n' > "$repo/scripts/broken.sh"   # missing fi
printf '#!/usr/bin/env python3\ndef f(:\n  pass\n' > "$repo/scripts/broken.py"
: > "$repo/scripts/empty.sh"
git -C "$repo" add -A
git -C "$repo" commit -q -m issues
out="$(scan "$none")"
grep -q 'BROKEN_SYNTAX :: scripts/broken.sh' <<<"$out" || fail "missing sh syntax candidate"
grep -q 'BROKEN_SYNTAX :: scripts/broken.py' <<<"$out" || fail "missing py syntax candidate"
grep -q 'EMPTY_FILE :: scripts/empty.sh' <<<"$out" || fail "missing empty-file candidate"
pass "detects broken shell, broken python and empty files"

# 3. An untracked top-level artifact is detected.
printf 'x\n' > "$repo/stray"
out="$(scan "$none")"
if grep -q 'UNTRACKED_ROOT :: stray' <<<"$out"; then fail "active untracked file became a candidate"; fi
pass "ignores active untracked files"

# 4. Output is byte-stable, so the monitor hash only moves on real change.
out2="$(scan "$none")"
[[ "$out" == "$out2" ]] || fail "output is not stable between runs"
pass "output is byte-stable between runs"

# 5. An open steward-cleanup card suppresses its candidate.
cid="$(grep 'BROKEN_SYNTAX :: scripts/broken.py' <<<"$out" | awk '{print $2}')"
[[ -n "$cid" ]] || fail "could not read the candidate id"
board="$fixture/board.db"
sqlite3 "$board" "CREATE TABLE tasks (id TEXT, tenant TEXT, status TEXT, idempotency_key TEXT);"
sqlite3 "$board" "INSERT INTO tasks VALUES ('t1','steward-cleanup','todo','steward-cleanup:$cid');"
out3="$(scan "$board")"
if grep -q 'BROKEN_SYNTAX :: scripts/broken.py' <<<"$out3"; then
  fail "a candidate covered by an open steward-cleanup card was not suppressed"
fi
pass "an open steward-cleanup card suppresses its candidate"

# 6. A completed card does not suppress — a resolved issue may legitimately recur.
sqlite3 "$board" "UPDATE tasks SET status='done' WHERE id='t1';"
out4="$(scan "$board")"
grep -q 'BROKEN_SYNTAX :: scripts/broken.py' <<<"$out4" || fail "a done card suppressed a candidate it should not"
pass "a completed card does not suppress its candidate"

# Active working edits must not create syntax candidates from a clean HEAD.
printf '#!/bin/sh\nexit 0\n' > "$repo/scripts/clean.sh"
git -C "$repo" add scripts/clean.sh
git -C "$repo" commit -q -m clean-script
printf '#!/bin/sh\nif (\n' > "$repo/scripts/clean.sh"
if scan "$none" | grep -q 'BROKEN_SYNTAX :: scripts/clean.sh'; then fail "active edit became a candidate"; fi
pass "checks committed content instead of transient working edits"

# No reaper or count-based cleanup is invoked, even when such a script exists.
mkdir -p "$repo/scripts/hermes"
printf '#!/bin/sh\ntouch "%s"\n' "$fixture/reaper-was-run" > "$repo/scripts/hermes/reap-kanban-worktrees.sh"
scan "$none" >/dev/null
[[ ! -e "$fixture/reaper-was-run" ]] || fail "scanner invoked the reaper"
pass "does not invoke cleanup or wake on counts"

# Current handoffs suppress a candidate across tenants, not only legacy cleanup.
sqlite3 "$board" "ALTER TABLE tasks ADD COLUMN title TEXT; ALTER TABLE tasks ADD COLUMN body TEXT;"
sqlite3 "$board" "INSERT INTO tasks VALUES ('t2','continuous-improvement','blocked',NULL,'Fix syntax','Scope: scripts/broken.py');"
if scan "$board" | grep -q 'BROKEN_SYNTAX :: scripts/broken.py'; then fail "open handoff was ignored"; fi
pass "deduplicates against current coordinator work"

echo "✅ steward-opportunity-scan"

# The scanner and report agent share the same read-only profile contract.
bash "$TESTS_REPO_ROOT/scripts/tests/test-steward-readonly.sh"
