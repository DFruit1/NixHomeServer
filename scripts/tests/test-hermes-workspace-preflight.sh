#!/usr/bin/env bash
# Regression test for scripts/hermes/kanban-workspace-preflight.py.
#
# Fleet evidence (parent t_73c1155c): an owner-alert candidate (pcops t_6e3059e2)
# stalled unmerged because its worktree was a SHALLOW clone -- the boundary
# object its gate needed was missing -- and the gate then hit a PermissionError
# outside its owned paths. Slice 1 removes that mechanical cause, so the
# preflight must DETECT a shallow clone, unreadable git metadata and an ancestor
# that denies worker search, print the exact remediation and exit 1.
#
# It is a detector, never a repairer: the fixture pins that a real
# `git clone --depth 1` still reports shallow after the run. Runs hermetically
# against real repositories under mktemp -d and a throwaway HERMES_ROOT, so the
# live boards are never scanned.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
ensure_tools git mktemp python3

preflight="$TESTS_REPO_ROOT/scripts/hermes/kanban-workspace-preflight.py"

root="$(mktemp -d)"
# The denied-ancestor fixture is mode 000; restore search before deleting it.
trap 'chmod -R u+rwx "$root" 2>/dev/null || true; rm -rf "$root"' EXIT

fail() { echo "$1" >&2; exit 1; }

make_board() {
  # make_board <kanban.db> <row>...   where each row is id|status|kind|path
  local db="$1"; shift
  python3 - "$db" "$@" <<'PY'
import sqlite3, sys
db, rows = sqlite3.connect(sys.argv[1]), sys.argv[2:]
db.execute('CREATE TABLE tasks(id TEXT PRIMARY KEY, status TEXT, '
           'workspace_kind TEXT, workspace_path TEXT)')
for row in rows:
    tid, status, kind, path = (row.split('|', 3) + [''])[:4]
    db.execute('INSERT INTO tasks VALUES (?,?,?,?)',
               (tid, status, kind, path or None))
db.commit()
PY
}

# --- a real upstream, so `--depth 1` truncates real history ------------------
seed="$root/seed"
git init -q "$seed"
git -C "$seed" config user.email test@example.com
git -C "$seed" config user.name test
printf 'one\n' >"$seed/history.txt"
git -C "$seed" add history.txt
git -C "$seed" commit -q -m one
printf 'two\n' >>"$seed/history.txt"
git -C "$seed" add history.txt
git -C "$seed" commit -q -m two

# --- the delegated checkout whose .worktrees/ fleet is scanned ---------------
repo="$root/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m init
mkdir -p "$repo/.worktrees"

git clone -q --depth 1 "file://$seed" "$repo/.worktrees/t_shallow"
git clone -q "file://$seed" "$repo/.worktrees/t_full"

# A worktree whose gitdir pointer is dead: its metadata cannot be read.
mkdir -p "$repo/.worktrees/t_broken"
printf 'gitdir: /nonexistent-gitdir\n' >"$repo/.worktrees/t_broken/.git"

# A shallow clone and a full clone owned by board cards.
git clone -q --depth 1 "file://$seed" "$root/board-shallow"
git clone -q "file://$seed" "$root/board-full"

# A full clone whose ancestor denies worker search.
git clone -q "file://$seed" "$root/denied/ws"
chmod 000 "$root/denied"

# A plain, non-git directory recorded as a `dir` workspace: not a worktree.
mkdir -p "$root/plain"

hermes="$root/hermes"
mkdir -p "$hermes/kanban/boards/preflight"
make_board "$hermes/kanban/boards/preflight/kanban.db" \
  "t_shallow|running|worktree|$root/board-shallow" \
  "t_full|running|worktree|$root/board-full" \
  "t_denied|running|worktree|$root/denied/ws" \
  "t_plain|running|dir|$root/plain" \
  "t_scratch|running|scratch|"

echo "▶ delegated workspace preflight contract"

# --- the detector fires on every hazard and exits 1 --------------------------

before_db="$(sha256sum "$hermes/kanban/boards/preflight/kanban.db" | cut -d' ' -f1)"

status=0
out="$(python3 "$preflight" --hermes-root "$hermes" --repo "$repo" 2>&1)" || status=$?
[[ "$status" -eq 1 ]] || { echo "$out" >&2; fail "❌ a shallow workspace must exit 1 (got $status)"; }

grep -Fq "shallow_history $root/board-shallow" <<<"$out" \
  || { echo "$out" >&2; fail "❌ a board worktree that is a shallow clone was not flagged"; }
grep -Fq "git -C $root/board-shallow fetch --unshallow" <<<"$out" \
  || { echo "$out" >&2; fail "❌ the shallow board worktree lacks the exact remediation"; }

grep -Fq "shallow_history $repo/.worktrees/t_shallow" <<<"$out" \
  || { echo "$out" >&2; fail "❌ a .worktrees/ entry that is a shallow clone was not flagged"; }
grep -Fq "git -C $repo/.worktrees/t_shallow fetch --unshallow" <<<"$out" \
  || { echo "$out" >&2; fail "❌ the shallow .worktrees entry lacks the exact remediation"; }

grep -Fq "unreadable_git_metadata $repo/.worktrees/t_broken" <<<"$out" \
  || { echo "$out" >&2; fail "❌ unreadable git metadata was not flagged"; }

grep -Fq "unsearchable_ancestor $root/denied/ws" <<<"$out" \
  || { echo "$out" >&2; fail "❌ an ancestor denying worker search was not flagged"; }
grep -Fq "chmod u+x $root/denied" <<<"$out" \
  || { echo "$out" >&2; fail "❌ the denied ancestor lacks its remediation"; }

if grep -Fq "$root/plain" <<<"$out"; then
  echo "$out" >&2
  fail "❌ a plain non-git dir workspace was wrongly treated as a git worktree"
fi
if grep -Fq "$repo/.worktrees/t_full" <<<"$out"; then
  echo "$out" >&2
  fail "❌ a full clone was wrongly flagged"
fi

echo "  ✅ shallow clones, unreadable metadata and denied ancestors are flagged with the exact fix"

# --- the detector repairs nothing and writes nothing -------------------------

[[ -f "$root/board-shallow/.git/shallow" ]] \
  || fail "❌ the preflight unshallowed a workspace instead of only reporting it"
[[ -f "$repo/.worktrees/t_shallow/.git/shallow" ]] \
  || fail "❌ the preflight unshallowed a .worktrees/ clone instead of only reporting it"
after_db="$(sha256sum "$hermes/kanban/boards/preflight/kanban.db" | cut -d' ' -f1)"
[[ "$before_db" == "$after_db" ]] \
  || fail "❌ the preflight modified a board database"
git -C "$root/board-shallow" rev-parse --is-shallow-repository | grep -qx true \
  || fail "❌ the preflight fetched into a shallow clone"

echo "  ✅ read-only: no unshallow, no fetch, no board write"

# --- a fleet of complete, readable worktrees exits 0 -------------------------

clean_repo="$root/clean-repo"
git init -q "$clean_repo"
git -C "$clean_repo" config user.email test@example.com
git -C "$clean_repo" config user.name test
git -C "$clean_repo" commit -q --allow-empty -m init
mkdir -p "$clean_repo/.worktrees"
git clone -q "file://$seed" "$clean_repo/.worktrees/t_full"
git clone -q "file://$seed" "$root/clean-board"

clean_hermes="$root/clean-hermes"
mkdir -p "$clean_hermes/kanban/boards/preflight"
make_board "$clean_hermes/kanban/boards/preflight/kanban.db" \
  "t_full|running|worktree|$root/clean-board"

if ! clean_out="$(python3 "$preflight" --hermes-root "$clean_hermes" --repo "$clean_repo" 2>&1)"; then
  echo "$clean_out" >&2
  fail "❌ a fleet of complete, readable worktrees must exit 0"
fi
grep -Fq "✅" <<<"$clean_out" \
  || { echo "$clean_out" >&2; fail "❌ a passing run must report success"; }

echo "  ✅ a full clone passes"
echo "✅ delegated workspace preflight contract passed"
