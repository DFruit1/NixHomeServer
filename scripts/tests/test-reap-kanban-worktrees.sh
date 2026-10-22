#!/usr/bin/env bash
# Regression test for scripts/hermes/reap-kanban-worktrees.sh.
#
# The reaper deletes directories, so this pins exactly which trees it may touch:
# only a terminal card's clean, fully published tree whose ignored content is
# reproducible scratch/build output. A tree owned by a non-terminal card, a
# dirty tree, a tree with unpublished commits, a tree with no owning card, a
# tree holding gitignored evidence, a broken worktree, a stale admin entry and
# an unregistered directory must all survive. It also pins that an unreadable or
# unexpected board aborts without removing anything, that archived cards are
# read, that relative card paths resolve against the repository, and that
# archived board copies stay outside the citation scan. The open-
# card citation guard keeps any tree an open card names in its title, body,
# comments or attachment names, and an unusable board database under HERMES_ROOT
# aborts the run instead of reaping unprotected. Runs hermetically against a
# throwaway repo with a stub `hermes`.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
ensure_tools git jq

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

git -C "$root" init -q
git -C "$root" config user.email test@example.com
git -C "$root" config user.name test
# Agent scratch and build output are reproducible; they must not block a reap.
printf '/.tmp/\n/result/\n' >"$root/.gitignore"
git -C "$root" add .gitignore
git -C "$root" commit -q -m init

# A remote-tracking ref makes the base commit "published".
base="$(git -C "$root" rev-parse HEAD)"
git -C "$root" update-ref refs/remotes/origin/main "$base"

# A local-only evidence document hidden through .git/info/exclude. `git status`
# calls the tree clean, so only the ignored-content check keeps it alive.
printf 'local-only-evidence.md\n' >>"$root/.git/info/exclude"

mkdir -p "$root/scripts/hermes" "$root/bin" "$root/.worktrees"
cp "$TESTS_REPO_ROOT/scripts/hermes/reap-kanban-worktrees.sh" "$root/scripts/hermes/"

add_tree() {
  git -C "$root" worktree add -q "$root/.worktrees/$1" -b "wt/$1"
}

add_tree t_merged          # terminal done card, clean, published -> reap
add_tree t_archived        # terminal archived card -> reap
add_tree t_scratch         # terminal card, only ignored scratch -> reap
add_tree t_active          # todo card -> preserve
add_tree t_relactive       # todo card with a relative path -> preserve
add_tree t_dirty           # uncommitted change -> preserve
add_tree t_unpublished     # unique commit not on a remote ref -> preserve
add_tree t_broken          # git status fails inside it -> preserve
add_tree t_ignored_evidence # gitignored evidence file -> preserve
add_tree t_unowned         # clean, published, but no card -> preserve
add_tree t_cited           # terminal card, clean, published, but an open card
                           # elsewhere cites the tree as retained evidence
add_tree t_stale           # registered but its directory is gone -> report

# t_unpublished: a commit only this branch knows about.
git -C "$root/.worktrees/t_unpublished" commit -q --allow-empty -m local-only

# t_dirty: an untracked file is dirt, exactly as hermes treats it.
: >"$root/.worktrees/t_dirty/scratch.txt"

# t_scratch: ignored scratch only, which is disposable.
mkdir -p "$root/.worktrees/t_scratch/.tmp"
: >"$root/.worktrees/t_scratch/.tmp/worker.log"

# t_ignored_evidence: an ignored document git would delete on removal.
: >"$root/.worktrees/t_ignored_evidence/local-only-evidence.md"

# t_broken: a worktree whose gitdir pointer is broken. `git status` fails
# there, and classifying that failure as clean would reap on a false negative.
printf 'gitdir: /nonexistent-gitdir\n' >"$root/.worktrees/t_broken/.git"

# t_stale: keep the admin entry, drop the directory.
rm -rf "$root/.worktrees/t_stale"

# An unregistered directory under .worktrees/ (a manual clone looks identical).
mkdir -p "$root/.worktrees/manual-clone"
: >"$root/.worktrees/manual-clone/README.md"

board="$root/bin/board.json"
jq -n --arg root "$root" '
  def card($id; $status; $path): {id: $id, status: $status, workspace_path: $path};
  [
    card("t_merged"; "done"; "\($root)/.worktrees/t_merged"),
    card("t_archived"; "archived"; "\($root)/.worktrees/t_archived"),
    card("t_scratch"; "done"; "\($root)/.worktrees/t_scratch"),
    card("t_active"; "todo"; "\($root)/.worktrees/t_active"),
    card("t_relactive"; "todo"; ".worktrees/t_relactive"),
    card("t_dirty"; "done"; "\($root)/.worktrees/t_dirty"),
    card("t_unpublished"; "done"; "\($root)/.worktrees/t_unpublished"),
    card("t_broken"; "done"; "\($root)/.worktrees/t_broken"),
    card("t_ignored_evidence"; "done"; "\($root)/.worktrees/t_ignored_evidence"),
    card("t_cited"; "done"; "\($root)/.worktrees/t_cited"),
    card("t_stale"; "done"; "\($root)/.worktrees/t_stale")
  ]' >"$board"

# The real CLI hides archived cards unless --archived is passed, so the stub
# does too: dropping the flag would turn t_archived into an unowned tree.
cat >"$root/bin/hermes" <<'EOF'
#!/usr/bin/env bash
archived=false
for arg in "$@"; do
  if [[ "$arg" == "--archived" ]]; then archived=true; fi
done
if [[ "$archived" == true ]]; then
  jq -c . "$BOARD"
else
  jq -c '[.[] | select(.status != "archived")]' "$BOARD"
fi
EOF
make_test_executable "$root/bin/hermes"

# A board whose JSON shape changed must abort, never silently strip ownership.
cat >"$root/bin/hermes-bad-shape" <<'EOF'
#!/usr/bin/env bash
printf '{"tasks":[{"id":"t_merged","status":"done"}]}\n'
EOF
make_test_executable "$root/bin/hermes-bad-shape"

cat >"$root/bin/hermes-unreadable" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
make_test_executable "$root/bin/hermes-unreadable"

cat >"$root/bin/hermes-empty" <<'EOF'
#!/usr/bin/env bash
printf '[]\n'
EOF
make_test_executable "$root/bin/hermes-empty"

reap="$root/scripts/hermes/reap-kanban-worktrees.sh"
run_reap() { HERMES_BIN="$root/bin/hermes" HERMES_ROOT="$root/hermes-home" BOARD="$board" bash "$reap" "$@"; }

# The citation guard reads board databases under HERMES_ROOT, cross-board.
hermes_home="$root/hermes-home"
mkdir -p "$hermes_home/kanban/boards/evidenceboard"
python3 - <<'PY' "$hermes_home/kanban/boards/evidenceboard/kanban.db"
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.executescript("""
CREATE TABLE tasks (id TEXT PRIMARY KEY, title TEXT, body TEXT, status TEXT);
CREATE TABLE task_comments (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, body TEXT);
CREATE TABLE task_attachments (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT, filename TEXT, stored_path TEXT);
""")
db.execute("INSERT INTO tasks VALUES ('t_opener', 'Verify retained producer evidence', ?, 'todo')",
           ("The frozen producer source lives at .worktrees/t_cited; consume it before any switch.",))
db.execute("INSERT INTO task_comments (task_id, body) VALUES ('t_opener', 'evidence packet expected in the t_cited workspace')")
db.commit()
PY

# Launch from outside every checkout. A relative .git lock must not be resolved
# against the caller's cwd (which may itself be a linked worktree's .git file),
# and a relative card workspace_path must not resolve there either.
mkdir "$root/unrelated working directory"
cd "$root/unrelated working directory"

echo "▶ kanban worktree reaper contract"

# --- dry run classifies without deleting -------------------------------------

dry="$(run_reap)"
grep -q 'Reapable (terminal card, clean, published): *3$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected exactly three reapable trees" >&2; exit 1; }
grep -q 'Preserve (active card): *2$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected both active cards' trees to be preserved" >&2; exit 1; }
grep -q 'Preserve (unowned tree): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the card-less tree to be preserved as unowned" >&2; exit 1; }
grep -q 'preserve (no owning card): .worktrees/t_unowned' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ the unowned tree was not reported" >&2; exit 1; }
grep -q 'Preserve (uncommitted changes): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the dirty tree to be preserved" >&2; exit 1; }
grep -q 'Preserve (unpublished commits): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the unpushed tree to be preserved" >&2; exit 1; }
grep -q 'Preserve (git status failed): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the broken worktree to be preserved as status-unknown" >&2; exit 1; }
grep -q 'Preserve (ignored content): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the ignored evidence tree to be preserved" >&2; exit 1; }
grep -q 'preserve (ignored content): .worktrees/t_ignored_evidence \[local-only-evidence.md\]' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ the ignored evidence tree was not reported with its path" >&2; exit 1; }
grep -q 'preserve (cited by open card evidenceboard/t_opener): .worktrees/t_cited' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ the cited tree was not preserved with its citing card" >&2; exit 1; }
grep -q 'Preserve (cited by open card): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected one cited tree to be preserved" >&2; exit 1; }
grep -q 'Stale admin entry (directory missing): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the stale admin entry to be reported" >&2; exit 1; }
grep -q 'Stray directory (unregistered): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the unregistered directory to be reported" >&2; exit 1; }
grep -q 'GiB' <<<"$dry" \
  && { echo "$dry" >&2; echo "❌ the default dry run walked du for byte accounting" >&2; exit 1; }
[[ -d "$root/.worktrees/t_merged" ]] || { echo "❌ dry run deleted a tree" >&2; exit 1; }

echo "  ✅ dry run classifies every case, keeps the cited tree and deletes nothing, without du walks"

# --- a broken board database fails the citation guard closed ------------------

mkdir -p "$hermes_home/kanban/boards/broken"
printf 'not a database' >"$hermes_home/kanban/boards/broken/kanban.db"
if broken_out="$(run_reap --apply 2>&1)"; then
  echo "$broken_out" >&2
  echo "❌ a broken board database was accepted by the citation guard" >&2
  exit 1
fi
grep -q 'Could not read open-card citations' <<<"$broken_out" \
  || { echo "$broken_out" >&2; echo "❌ the citation-guard failure was not reported" >&2; exit 1; }
[[ -d "$root/.worktrees/t_merged" && -d "$root/.worktrees/t_cited" ]] \
  || { echo "❌ a tree was removed while the citation source was unusable" >&2; exit 1; }
rm "$hermes_home/kanban/boards/broken/kanban.db" && rmdir "$hermes_home/kanban/boards/broken"

# An archived board copy is legacy-shape by design and cannot hold open cards.
mkdir -p "$hermes_home/kanban/boards/_archived"
printf 'legacy-archive' >"$hermes_home/kanban/boards/_archived/kanban.db"
archived_out="$(run_reap)"
grep -q 'Reapable (terminal card, clean, published): *3$' <<<"$archived_out" \
  || { echo "$archived_out" >&2; echo "❌ a legacy archived board copy failed the citation guard" >&2; exit 1; }
rm "$hermes_home/kanban/boards/_archived/kanban.db" && rmdir "$hermes_home/kanban/boards/_archived"

echo "  ✅ an unusable citation source aborts without removing anything; archived board copies are skipped"

# --- --bytes adds the accounting the cheap default leaves out -----------------

dry_bytes="$(run_reap --bytes)"
grep -q 'Reapable (terminal card, clean, published): *3 (' <<<"$dry_bytes" \
  || { echo "$dry_bytes" >&2; echo "❌ --bytes did not annotate the reapable count" >&2; exit 1; }

echo "  ✅ --bytes adds byte accounting to every summary line"

# --- an unusable board fails closed, before any removal ----------------------

for stub in hermes-bad-shape hermes-unreadable hermes-empty; do
  if out="$(HERMES_BIN="$root/bin/$stub" bash "$reap" --apply 2>&1)"; then
    echo "$out" >&2
    echo "❌ $stub was accepted instead of aborting" >&2
    exit 1
  fi
  [[ -d "$root/.worktrees/t_merged" ]] \
    || { echo "❌ $stub removed a tree before failing" >&2; exit 1; }
done

echo "  ✅ a malformed, unreadable or empty board aborts without removing anything"

# --- an overlapping reap skips rather than racing -----------------------------

git_dir="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)"
exec 9>"$git_dir/reap-kanban-worktrees.lock"
flock 9
lock_out="$(run_reap 2>&1)" || true
grep -q 'Another reap run holds the lock; skipping' <<<"$lock_out" \
  || { echo "$lock_out" >&2; echo "❌ an overlapping reap did not skip" >&2; exit 1; }

linked="$root/.worktrees/t_active"
mkdir -p "$linked/scripts/hermes" "$linked/.worktrees"
cp "$reap" "$linked/scripts/hermes/"
linked_out="$(HERMES_BIN="$root/bin/hermes" HERMES_ROOT="$root/hermes-home" BOARD="$board" bash "$linked/scripts/hermes/reap-kanban-worktrees.sh" 2>&1)"
grep -q 'Another reap run holds the lock; skipping' <<<"$linked_out" \
  || { echo "$linked_out" >&2; echo "❌ a linked checkout did not share the repository lock" >&2; exit 1; }
exec 9>&-

# A linked checkout's copy must still target the primary checkout's .worktrees.
# Its own .worktrees/ is empty, so a script-relative root would silently reap
# nothing while real trees accumulate.
linked_dry="$(HERMES_BIN="$root/bin/hermes" HERMES_ROOT="$root/hermes-home" BOARD="$board" bash "$linked/scripts/hermes/reap-kanban-worktrees.sh" 2>&1)"
grep -q 'Reapable (terminal card, clean, published): *3$' <<<"$linked_dry" \
  || { echo "$linked_dry" >&2; echo "❌ a run from a linked checkout did not target the primary .worktrees" >&2; exit 1; }

echo "  ✅ an overlapping reap skips while the lock is held"
echo "  ✅ a linked checkout reaps the primary checkout's trees, not its own empty directory"

# --- apply removes exactly the reapable trees --------------------------------

run_reap --apply >/dev/null

for gone in t_merged t_archived t_scratch; do
  [[ ! -d "$root/.worktrees/$gone" ]] || { echo "❌ $gone was not reaped" >&2; exit 1; }
done
for kept in t_active t_relactive t_dirty t_cited t_unpublished t_broken t_ignored_evidence t_unowned; do
  [[ -d "$root/.worktrees/$kept" ]] || { echo "❌ $kept was reaped" >&2; exit 1; }
done
[[ -f "$root/.worktrees/t_ignored_evidence/local-only-evidence.md" ]] \
  || { echo "❌ the ignored evidence file was deleted" >&2; exit 1; }
[[ -d "$root/.worktrees/manual-clone" ]] \
  || { echo "❌ an unregistered directory was deleted" >&2; exit 1; }
if git -C "$root" worktree list --porcelain | grep -q "\.worktrees/t_merged"; then
  echo "❌ reaped tree still registered with git" >&2
  exit 1
fi
git -C "$root" rev-parse --verify -q refs/heads/wt/t_merged >/dev/null \
  || { echo "❌ the local wt/ branch was deleted with the tree" >&2; exit 1; }
if git -C "$root" worktree list --porcelain | grep -q "\.worktrees/t_stale"; then
  echo "❌ the stale admin entry survived --apply" >&2
  exit 1
fi

echo "  ✅ apply reaps only terminal, clean, published trees with disposable ignored content"

# --- ignored evidence needs an explicit opt-in -------------------------------

run_reap --apply --accept-ignored >/dev/null
[[ ! -d "$root/.worktrees/t_ignored_evidence" ]] \
  || { echo "❌ --accept-ignored did not reap the ignored-evidence tree" >&2; exit 1; }

echo "  ✅ --accept-ignored is the only way past the ignored-content guard"

# --- unowned trees need an explicit opt-in -----------------------------------

run_reap --apply --include-unowned >/dev/null
[[ ! -d "$root/.worktrees/t_unowned" ]] \
  || { echo "❌ --include-unowned did not reap the card-less published tree" >&2; exit 1; }
[[ -d "$root/.worktrees/t_dirty" && -d "$root/.worktrees/t_unpublished" ]] \
  || { echo "❌ --include-unowned bypassed the dirty/unpublished guards" >&2; exit 1; }
[[ -d "$root/.worktrees/manual-clone" ]] \
  || { echo "❌ --include-unowned deleted an unregistered directory" >&2; exit 1; }

echo "  ✅ --include-unowned reaps only clean, published, card-less trees"
echo "✅ kanban worktree reaper contract passed"
