#!/usr/bin/env bash
# Regression test for scripts/hermes/reap-kanban-worktrees.sh.
#
# The reaper deletes directories, so this pins exactly which trees it may touch:
# only a terminal card's tree that is clean AND fully published. A tree owned by
# a non-terminal card, a dirty tree, or a tree with unpublished commits must
# survive. Runs hermetically against a throwaway repo with a stub `hermes`.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
ensure_tools git jq

root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

git -C "$root" init -q
git -C "$root" config user.email test@example.com
git -C "$root" config user.name test
git -C "$root" commit -q --allow-empty -m init

# A remote-tracking ref makes the base commit "published".
base="$(git -C "$root" rev-parse HEAD)"
git -C "$root" update-ref refs/remotes/origin/main "$base"

mkdir -p "$root/scripts/hermes" "$root/bin" "$root/.worktrees"
cp "$TESTS_REPO_ROOT/scripts/hermes/reap-kanban-worktrees.sh" "$root/scripts/hermes/"

add_tree() {
  git -C "$root" worktree add -q "$root/.worktrees/$1" -b "wt/$1"
}

add_tree t_merged      # terminal, clean, published -> reap
add_tree t_active      # active card -> preserve
add_tree t_dirty       # uncommitted change -> preserve
add_tree t_unpublished # unique commit not on a remote ref -> preserve
add_tree t_broken     # git status fails inside it -> preserve

# t_unpublished: a commit only this branch knows about.
git -C "$root/.worktrees/t_unpublished" commit -q --allow-empty -m local-only

# t_dirty: an untracked file is dirt, exactly as hermes treats it.
: >"$root/.worktrees/t_dirty/scratch.txt"

# t_broken: a worktree whose gitdir pointer is broken. `git status` fails
# there, and classifying that failure as clean would reap on a false negative.
printf 'gitdir: /nonexistent-gitdir\n' >"$root/.worktrees/t_broken/.git"

# The stub board reports only t_active as non-terminal.
cat >"$root/bin/hermes" <<EOF
#!/usr/bin/env bash
cat <<JSON
[{"id":"t_active","status":"todo","workspace_kind":"worktree","workspace_path":"$root/.worktrees/t_active","branch_name":"wt/t_active"}]
JSON
EOF
chmod +x "$root/bin/hermes"

reap="$root/scripts/hermes/reap-kanban-worktrees.sh"

echo "▶ kanban worktree reaper contract"

# --- dry run classifies without deleting -------------------------------------

dry="$(HERMES_BIN="$root/bin/hermes" bash "$reap")"
grep -q 'Reapable (terminal card, clean, published): 1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected exactly one reapable tree" >&2; exit 1; }
grep -q 'Preserve (active card): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the active card's tree to be preserved" >&2; exit 1; }
grep -q 'Preserve (uncommitted changes): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the dirty tree to be preserved" >&2; exit 1; }
grep -q 'Preserve (unpublished commits): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the unpushed tree to be preserved" >&2; exit 1; }
grep -q 'Preserve (git status failed): *1$' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the broken worktree to be preserved as status-unknown" >&2; exit 1; }
grep -q 'GiB' <<<"$dry" \
  && { echo "$dry" >&2; echo "❌ the default dry run walked du for byte accounting" >&2; exit 1; }
[[ -d "$root/.worktrees/t_merged" ]] || { echo "❌ dry run deleted a tree" >&2; exit 1; }

echo "  ✅ dry run classifies the five cases and deletes nothing, without du walks"

# --- --bytes adds the accounting the cheap default leaves out -----------------

dry_bytes="$(HERMES_BIN="$root/bin/hermes" bash "$reap" --bytes)"
grep -q 'Reapable (terminal card, clean, published): 1 (' <<<"$dry_bytes" \
  || { echo "$dry_bytes" >&2; echo "❌ --bytes did not annotate the reapable count" >&2; exit 1; }

echo "  ✅ --bytes adds byte accounting to every summary line"

# --- an overlapping reap skips rather than racing -----------------------------

git_dir="$(git -C "$root" rev-parse --git-dir)"
exec 9>"$git_dir/reap-kanban-worktrees.lock"
flock 9
lock_out="$(HERMES_BIN="$root/bin/hermes" bash "$reap" 2>&1)" || true
grep -q 'Another reap run holds the lock; skipping' <<<"$lock_out" \
  || { echo "$lock_out" >&2; echo "❌ an overlapping reap did not skip" >&2; exit 1; }
exec 9>&-

echo "  ✅ an overlapping reap skips while the lock is held"

# --- apply removes exactly the reapable tree ---------------------------------

HERMES_BIN="$root/bin/hermes" bash "$reap" --apply >/dev/null

[[ ! -d "$root/.worktrees/t_merged" ]] || { echo "❌ t_merged was not reaped" >&2; exit 1; }
[[ -d "$root/.worktrees/t_active" ]] || { echo "❌ an active card's tree was reaped" >&2; exit 1; }
[[ -d "$root/.worktrees/t_dirty" ]] || { echo "❌ a dirty tree was reaped" >&2; exit 1; }
[[ -d "$root/.worktrees/t_unpublished" ]] || { echo "❌ a tree with unpublished commits was reaped" >&2; exit 1; }
[[ -d "$root/.worktrees/t_broken" ]] || { echo "❌ a worktree whose git status failed was reaped" >&2; exit 1; }
if git -C "$root" worktree list --porcelain | grep -q "\.worktrees/t_merged"; then
  echo "❌ reaped tree still registered with git" >&2
  exit 1
fi

echo "  ✅ apply reaps only the terminal, clean, published tree"
echo "✅ kanban worktree reaper contract passed"
