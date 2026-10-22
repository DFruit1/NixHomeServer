#!/usr/bin/env bash
# Regression test for scripts/hermes/worktree-merge-back.py.
#
# Why this needs pinning
# ----------------------
# The helper is the coordinator's merge-back instrument and it runs git state
# transitions unattended-from-a-card. Its dangerous edges are pinned here:
# a merge that silently succeeded without content, a merge of rejected or
# unreviewed work, an auto-resolved conflict, a broken master after a failed
# validation, a disposition that suppresses a finding without being on record,
# and a push the helper was never authorized to make.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$TESTS_REPO_ROOT/scripts/hermes/worktree-merge-back.py"

fail() { echo "❌ $1" >&2; exit 1; }
pass() { echo "  ✅ $1"; }

[[ -f "$HELPER" ]] || fail "worktree-merge-back.py is missing"

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

root="$fixture/hermes"
board_dir="$root/kanban/boards/testboard"
mkdir -p "$board_dir" "$root/scripts"
repo="$fixture/project"

# Board with the full tasks schema the helper reads.
sqlite3 "$board_dir/kanban.db" <<'SQL'
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT,
  created_at INTEGER, started_at INTEGER, workspace_path TEXT,
  branch_name TEXT, completed_at INTEGER, project_id TEXT,
  claim_lock TEXT, block_kind TEXT, block_recurrences INTEGER DEFAULT 0,
  consecutive_failures INTEGER DEFAULT 0
);
CREATE TABLE task_comments (id INTEGER PRIMARY KEY, task_id TEXT, body TEXT, author TEXT);
CREATE TABLE task_events (id INTEGER PRIMARY KEY, task_id TEXT, kind TEXT, payload TEXT);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
SQL
printf '{"slug": "testboard", "default_workdir": "%s"}\n' "$repo" >"$board_dir/board.json"

# The project checkout the board works in. Has no validate-repo.sh of its own,
# so the validation leg reports 'skipped' in receipts.
mkdir -p "$repo"
git -C "$repo" init --quiet --initial-branch master 2>/dev/null || git -C "$repo" init --quiet
printf 'base\n' >"$repo/base.txt"; git -C "$repo" add base.txt
git -C "$repo" commit -m base --quiet
git -C "$repo" config user.email test@fixture
git -C "$repo" config user.name test

# A stub CLI that records comments exactly like the native kanban tool would,
# without involving a live board engine: the helper's disposition write path
# is the thing under test, and the recorded row must carry head-coordinator.
mkdir -p "$fixture/bin"
cat >"$fixture/bin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# helper invokes: hermes kanban --board <slug> comment <task> <message>
[[ "${1:-}" == kanban && "${2:-}" == --board && "${4:-}" == comment ]] || exit 64
db="$HERMES_KANBAN_HOME/kanban/boards/$3/kanban.db"
task="$5" msg="$6"
sqlite3 "$db" "INSERT INTO task_comments (task_id, body, author)
  SELECT '$task', '$msg', 'head-coordinator';"
echo "commented $task"
EOF
chmod +x "$fixture/bin/hermes"

mb() { HERMES_ROOT="$root" HERMES_BOARD=testboard HERMES_BIN="$fixture/bin/hermes" \
  python3 -B "$HELPER" "$@"; }

card() {
  local id="$1" title="$2" branch="$3" status="${4:-done}"
  sqlite3 "$board_dir/kanban.db" "INSERT INTO tasks
    (id,title,assignee,status,completed_at,branch_name) VALUES
    ('$id','$title','standard-implementer','$status',$(date +%s),'$branch');"
}

make_branch() { # id, one commit per printf-pair
  local id="$1"; shift
  git -C "$repo" checkout --quiet -b "wt/$id"
  local p
  for p in "$@"; do printf '%s\n' "$p" >"$repo/$id.txt"; git -C "$repo" add "$id.txt"; git -C "$repo" commit -m "$id $p" --quiet; done
  git -C "$repo" checkout --quiet master
}

echo "▶ worktree merge-back helper"

# --- list, plan, merge, idempotence ------------------------------------------

make_branch t_ok one two
card t_ok "accepted work" wt/t_ok

out=$(mb --list)
grep -q '^UNMERGED_ACCEPTED_WORK t_ok branch=wt/t_ok commits=2 card=done$' <<<"$out" ||
  fail "did not list the accepted unmerged branch: $out"
pass "lists the accepted unmerged branch"

out=$(mb --plan wt/t_ok)
grep -q '"status": "clean-plan"' <<<"$out" || fail "plan did not classify a clean branch: $out"
grep -q '"commits_unapplied": 2' <<<"$out" || fail "plan lost the commit census: $out"
pass "plans a clean branch with its commit census"

out=$(mb --merge wt/t_ok)
[[ $? -eq 0 ]] || fail "clean merge exited nonzero: $out"
git -C "$repo" merge-base --is-ancestor wt/t_ok master || fail "the branch commits did not reach master"
git -C "$repo" show --format='%P' -s master | grep -q ' ' ||
  fail "the merge was not a non-ff merge commit"
out=$(mb --merge wt/t_ok)
grep -q '"status": "already_integrated"' <<<"$out" || fail "a second merge re-merged: $out"
pass "merges once, then reports already integrated"

# The next list is quiet for the branched card.
[[ -z "$(mb --list)" ]] || fail "list still reported the merged branch"
pass "list goes quiet once merged"

# --- refusals -----------------------------------------------------------------

git -C "$repo" checkout --quiet -b feature 2>/dev/null || true
make_branch t_d detached-but-done
card t_d "done card, detached checkout" wt/t_d done
git -C "$repo" checkout --quiet master 2>/dev/null
git -C "$repo" checkout --detach --quiet
out=$(mb --merge wt/t_d 2>&1 || true)
grep -q 'MERGE_BACK_REFUSED NOT_ON_MASTER' <<<"$out" || fail "no clear refusal off master: $out"
git -C "$repo" checkout --quiet master || git -C "$repo" checkout --quiet -f master
pass "refuses to merge when the checkout is not on master"

make_branch t_open fastwait
card t_open "open card" wt/t_open open
open_receipt=$(mb --merge wt/t_open 2>&1 || true)
grep -q 'MERGE_BACK_REFUSED NO_ACCEPTED_CARD' <<<"$open_receipt" || fail "an open card merge was not refused: $open_receipt"
pass "refuses to merge a card that is not done or archived"

printf 'dirt\n' >"$repo/dirt.txt"
out=$(mb --merge wt/t_d 2>&1 || true)
grep -q 'MERGE_BACK_REFUSED UNCLEAN_WORKTREE' <<<"$out" || fail "dirty repository was silent: $out"
rm -f "$repo/dirt.txt"
pass "refuses to merge a dirty worktree"

# --- conflict evidence, never auto-resolution --------------------------------

make_branch t_conf payload
card t_conf "conflicting accepted fix" wt/t_conf
printf 'master-side\n' >"$repo/t_conf.txt"
git -C "$repo" add t_conf.txt; git -C "$repo" commit -m 'master side of t_conf' --quiet

# fastwait fix: no wait, t_conf's branch must conflict on the same path:
git -C "$repo" checkout --quiet wt/t_conf
printf 'branch-side\n' >"$repo/t_conf.txt"
git -C "$repo" add t_conf.txt; git -C "$repo" commit -m 'branch side of t_conf' --quiet
git -C "$repo" checkout --quiet master

out=$(mb --merge wt/t_conf) && code=0 || code=$?
[[ "$code" == 3 ]] || fail "conflict merge exited $code: $out"
grep -q '"status": "conflict"' <<<"$out" || fail "conflict receipt missing: $out"
grep -q 't_conf.txt' <<<"$out" || fail "conflict receipt names no file: $out"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "a conflicted merge left the worktree dirty"
git -C "$repo" merge-base --is-ancestor wt/t_conf master && fail "a conflicted branch reached master anyway"
before="$(git -C "$repo" rev-parse master)"
pass "reports conflicts with files and leaves master untouched"

out=$(mb --plan wt/t_conf)
grep -q '"status": "conflict-plan"' <<<"$out" || fail "plan missed the conflict: $out"
pass "plans a conflict with file evidence"

# --- disposition via the native comment path ---------------------------------

out=$(mb --dispose wt/t_conf --reason 'superseded by the composition route; keep worktree evidence only')
grep -q '"status": "disposed"' <<<"$out" || fail "dispose refused: $out"
sqlite3 "$board_dir/kanban.db" "SELECT body FROM task_comments WHERE author='head-coordinator';" |
  grep -q '^merge-back disposition: superseded by the composition route; keep worktree evidence only' ||
  fail "the disposition comment is not on record"
list_after="$(mb --list)"
grep -q 't_conf' <<<"$list_after" && fail "list still reports the dispositioned branch: $list_after"
pass "records a disposition and silences the finding"

# Missing reason is refused rather than recorded blank.
if mb --dispose wt/t_ok >/dev/null 2>&1; then fail "dispose without reason was accepted"; fi
pass "refuses a disposition without a reason"

# --- no push, no remote touching ---------------------------------------------

[[ -z "$(git -C "$repo" remote)" ]] || fail "the helper created a remote"
pass "never touches remote state"

echo "▶ worktree merge-back: all checks passed"
