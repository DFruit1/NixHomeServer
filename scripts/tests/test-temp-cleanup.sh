#!/usr/bin/env bash
# Regression test for scripts/admin/temp-cleanup.sh.
#
# The cleanup deletes directories, so this pins exactly what it may remove:
# only entries inside the allowlisted roots that are older than retention and
# contain no protected content. Recorded work, databases, secrets, model
# weights, symlinks, mount points and repositories must survive. Runs
# hermetically against a throwaway home, repository and tmp directory.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
ensure_tools git jq

root="$(mktemp -d)"
trap 'chmod -R u+rwX "$root" 2>/dev/null || true; rm -rf "$root"' EXIT

home="$root/home"
hermes="$home/.hermes"
repo="$root/repo"
tmp="$root/tmp"
state="$root/state"
mkdir -p "$home" "$hermes" "$repo" "$tmp" "$state"

mkdir -p "$root/scripts/admin" "$root/scripts/hermes"
cp "$TESTS_REPO_ROOT/scripts/admin/temp-cleanup.sh" "$root/scripts/admin/"
cleanup="$root/scripts/admin/temp-cleanup.sh"

backdate() { touch -d '40 days ago' -- "$@"; }
backdate_tree() { # set an old mtime after its contents exist
  touch -d '40 days ago' -- "$@"
}

# --- Hermes caches and logs --------------------------------------------------

mkdir -p "$hermes/cache/old-cache" "$hermes/cache/new-cache"
: >"$hermes/cache/old-cache/data"
: >"$hermes/cache/new-cache/data"
backdate "$hermes/cache/old-cache/data"; backdate "$hermes/cache/old-cache"

# A cached database snapshot and an encrypted archive are high-value data.
mkdir -p "$hermes/cache/db-snapshot"
: >"$hermes/cache/db-snapshot/state.db"
backdate "$hermes/cache/db-snapshot/state.db"; backdate "$hermes/cache/db-snapshot"
: >"$hermes/cache/evidence.age"
backdate "$hermes/cache/evidence.age"

# A cached checkout is not temp data.
mkdir -p "$hermes/cache/cached-repo/.git"
: >"$hermes/cache/cached-repo/.git/HEAD"
backdate "$hermes/cache/cached-repo/.git/HEAD"; backdate_tree "$hermes/cache/cached-repo"

# A symlink is never followed or removed; its target lives outside every root.
mkdir -p "$home/valuable-data"
: >"$home/valuable-data/keep"
ln -s "$home/valuable-data" "$hermes/cache/old-link"
touch -h -d '40 days ago' -- "$hermes/cache/old-link"

mkdir -p "$hermes/logs"
: >"$hermes/logs/old.log"
: >"$hermes/logs/current.log"
backdate "$hermes/logs/old.log"

mkdir -p "$hermes/profiles/p1/cache/old-cache" "$hermes/profiles/p1/scratch/old-scratch" \
  "$hermes/profiles/p1/logs"
: >"$hermes/profiles/p1/cache/old-cache/data"
: >"$hermes/profiles/p1/scratch/old-scratch/data"
: >"$hermes/profiles/p1/logs/old.log"
backdate_tree "$hermes/profiles/p1/cache/old-cache"
backdate_tree "$hermes/profiles/p1/scratch/old-scratch"
backdate "$hermes/profiles/p1/logs/old.log"

# Never auto-deleted: managed runtimes and project environments are reported.
mkdir -p "$hermes/tools/old-tool" "$hermes/installs/old-install"
: >"$hermes/tools/old-tool/data"
: >"$hermes/installs/old-install/data"
backdate_tree "$hermes/tools/old-tool"
backdate_tree "$hermes/installs/old-install"

# --- tmp and repository scratch ---------------------------------------------

mkdir -p "$tmp/nixhomeserver-old" "$tmp/nixhomeserver-new" "$tmp/hermes-old" "$tmp/unrelated-old"
: >"$tmp/nixhomeserver-old/data"; : >"$tmp/hermes-old/data"; : >"$tmp/unrelated-old/data"
backdate_tree "$tmp/nixhomeserver-old"
backdate_tree "$tmp/hermes-old"
backdate_tree "$tmp/unrelated-old"

mkdir -p "$repo/.tmp/old-task" "$repo/.tmp/new-task" "$repo/output" "$repo/test-results" \
  "$repo/playwright-report"
: >"$repo/.tmp/old-task/notes"
: >"$repo/.tmp/new-task/notes"
: >"$repo/output/old.png"
: >"$repo/test-results/old.json"
: >"$repo/playwright-report/old.html"
backdate_tree "$repo/.tmp/old-task"
backdate "$repo/output/old.png"
backdate "$repo/test-results/old.json"
backdate "$repo/playwright-report/old.html"

run_cleanup() {
  HOME="$home" \
  TEMP_CLEANUP_HERMES_HOME="$hermes" \
  TEMP_CLEANUP_REPO_PATH="$repo" \
  TEMP_CLEANUP_TMP_DIR="$tmp" \
  TEMP_CLEANUP_STATE_DIR="$state" \
  bash "$cleanup" "$@"
}

echo "▶ Hermes and development temp cleanup"

# --- dry run never deletes ---------------------------------------------------

dry="$(run_cleanup)"
grep -q 'would remove (hermes cache): ~/.hermes/cache/old-cache' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the aged cache entry to be classified" >&2; exit 1; }
grep -q 'would remove (hermes log): ~/.hermes/logs/old.log' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected the aged log file to be classified" >&2; exit 1; }
grep -q 'would remove (tmp): .*/nixhomeserver-old' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected aged tooling scratch in /tmp to be classified" >&2; exit 1; }
grep -q 'would remove (repo scratch): .*/.tmp/old-task' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected aged repository scratch to be classified" >&2; exit 1; }
grep -q 'would remove (repo output): .*/output' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected aged repository output to be classified" >&2; exit 1; }
grep -q 'would remove (profile scratch)' <<<"$dry" \
  && { echo "$dry" >&2; echo "❌ profile scratch was scanned without --include-scratch" >&2; exit 1; }
grep -q 'hermes install' <<<"$dry" \
  && { echo "$dry" >&2; echo "❌ Hermes installs were scanned without --include-installs" >&2; exit 1; }
grep -q 'unrelated-old' <<<"$dry" \
  && { echo "$dry" >&2; echo "❌ an unrelated /tmp directory was classified" >&2; exit 1; }
[[ -d "$hermes/cache/old-cache" ]] || { echo "❌ dry run deleted a cache entry" >&2; exit 1; }

echo "  ✅ dry run classifies only allowlisted, aged, unprotected entries"

# --- apply deletes exactly the safe entries ---------------------------------

run_cleanup --apply >/dev/null

[[ ! -e "$hermes/cache/old-cache" ]] || { echo "❌ aged cache entry was not removed" >&2; exit 1; }
[[ -e "$hermes/cache/evidence.age" ]] || { echo "❌ encrypted evidence archive was deleted" >&2; exit 1; }
[[ -d "$hermes/cache/db-snapshot" ]] || { echo "❌ cached database snapshot was deleted" >&2; exit 1; }
[[ -d "$hermes/cache/cached-repo" ]] || { echo "❌ cached git checkout was deleted" >&2; exit 1; }
[[ -L "$hermes/cache/old-link" && -d "$home/valuable-data" ]] \
  || { echo "❌ a symlink or its target was deleted" >&2; exit 1; }
[[ -d "$hermes/cache/new-cache" ]] || { echo "❌ a recent cache entry was deleted" >&2; exit 1; }
[[ ! -e "$hermes/logs/old.log" && -e "$hermes/logs/current.log" ]] \
  || { echo "❌ log retention was not applied exactly" >&2; exit 1; }
[[ ! -e "$hermes/profiles/p1/cache/old-cache" ]] || { echo "❌ profile cache was not removed" >&2; exit 1; }
[[ ! -e "$hermes/profiles/p1/logs/old.log" ]] || { echo "❌ profile log was not removed" >&2; exit 1; }
[[ -d "$hermes/profiles/p1/scratch/old-scratch" ]] \
  || { echo "❌ profile scratch was removed without --include-scratch" >&2; exit 1; }
[[ -d "$hermes/tools/old-tool" && -d "$hermes/installs/old-install" ]] \
  || { echo "❌ managed runtimes or installs were removed without a flag" >&2; exit 1; }
[[ ! -e "$tmp/nixhomeserver-old" && -e "$tmp/nixhomeserver-new" && -e "$tmp/unrelated-old" ]] \
  || { echo "❌ /tmp cleanup was not limited to aged tooling scratch" >&2; exit 1; }
[[ ! -e "$tmp/hermes-old" ]] || { echo "❌ aged Hermes scratch in /tmp was not removed" >&2; exit 1; }
[[ ! -e "$repo/.tmp/old-task" && -d "$repo/.tmp/new-task" ]] \
  || { echo "❌ repository scratch retention was not applied exactly" >&2; exit 1; }
[[ ! -e "$repo/output/old.png" && ! -e "$repo/test-results/old.json" && ! -e "$repo/playwright-report/old.html" ]] \
  || { echo "❌ aged generated output was not removed" >&2; exit 1; }

echo "  ✅ apply removes only aged, unprotected entries and keeps valuable data"

# --- opt-in scratch and installs --------------------------------------------

run_cleanup --apply --include-scratch --include-installs >/dev/null
[[ ! -e "$hermes/profiles/p1/scratch/old-scratch" ]] \
  || { echo "❌ --include-scratch did not remove aged scratch" >&2; exit 1; }
[[ ! -e "$hermes/installs/old-install" ]] \
  || { echo "❌ --include-installs did not remove the aged project environment" >&2; exit 1; }
[[ -d "$hermes/tools/old-tool" ]] \
  || { echo "❌ managed Hermes runtimes must never be auto-deleted" >&2; exit 1; }

echo "  ✅ scratch and project environments require explicit opt-in"

# --- worktrees are delegated to the audited tools ---------------------------

mkdir -p "$hermes/hermes-agent/.git"
cat >"$root/fake-hermes" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_HERMES_LOG"
EOF
make_test_executable "$root/fake-hermes"
cat >"$root/scripts/hermes/reap-kanban-worktrees.sh" <<'EOF'
#!/usr/bin/env bash
printf 'fake-reaper HERMES_BIN=%s %s\n' "${HERMES_BIN:-}" "$*" >>"$FAKE_HERMES_LOG"
EOF
make_test_executable "$root/scripts/hermes/reap-kanban-worktrees.sh"
: >"$root/fake.log"

HOME="$home" TEMP_CLEANUP_HERMES_HOME="$hermes" TEMP_CLEANUP_REPO_PATH="$repo" \
  TEMP_CLEANUP_TMP_DIR="$tmp" TEMP_CLEANUP_STATE_DIR="$state" \
  TEMP_CLEANUP_HERMES_BIN="$root/fake-hermes" FAKE_HERMES_LOG="$root/fake.log" \
  bash "$cleanup" --include-worktrees >/dev/null
grep -q 'worktree list --repo ' "$root/fake.log" \
  || { cat "$root/fake.log" >&2; echo "❌ dry run did not audit Hermes worktrees" >&2; exit 1; }
grep -q 'fake-reaper HERMES_BIN=.* $' "$root/fake.log" \
  || { cat "$root/fake.log" >&2; echo "❌ dry run did not audit kanban worktrees" >&2; exit 1; }

: >"$root/fake.log"
HOME="$home" TEMP_CLEANUP_HERMES_HOME="$hermes" TEMP_CLEANUP_REPO_PATH="$repo" \
  TEMP_CLEANUP_TMP_DIR="$tmp" TEMP_CLEANUP_STATE_DIR="$state" \
  TEMP_CLEANUP_HERMES_BIN="$root/fake-hermes" FAKE_HERMES_LOG="$root/fake.log" \
  bash "$cleanup" --include-worktrees --apply >/dev/null
grep -q 'worktree prune --repo ' "$root/fake.log" \
  || { cat "$root/fake.log" >&2; echo "❌ --apply did not run Hermes worktree prune" >&2; exit 1; }
grep -q 'fake-reaper HERMES_BIN=.* --apply$' "$root/fake.log" \
  || { cat "$root/fake.log" >&2; echo "❌ --apply did not run the kanban worktree reaper" >&2; exit 1; }

echo "  ✅ worktrees are delegated to the audited Hermes and kanban tools"

# --- missing roots are harmless ---------------------------------------------

out="$(HOME="$home" TEMP_CLEANUP_HERMES_HOME="$root/absent" TEMP_CLEANUP_REPO_PATH="$root/absent" \
  TEMP_CLEANUP_TMP_DIR="$root/absent" TEMP_CLEANUP_STATE_DIR="$state" bash "$cleanup" --apply)"
grep -q 'Removed: *0' <<<"$out" \
  || { echo "$out" >&2; echo "❌ a missing root was not treated as empty" >&2; exit 1; }

echo "  ✅ missing roots are skipped without failure"

# --- overlapping runs skip ---------------------------------------------------

exec 9>"$state/temp-cleanup.lock"
flock 9
lock_out="$(HOME="$home" TEMP_CLEANUP_HERMES_HOME="$hermes" TEMP_CLEANUP_REPO_PATH="$repo" \
  TEMP_CLEANUP_TMP_DIR="$tmp" TEMP_CLEANUP_STATE_DIR="$state" bash "$cleanup" 2>&1)"
exec 9>&-
grep -q 'Another temp cleanup holds the lock; skipping' <<<"$lock_out" \
  || { echo "$lock_out" >&2; echo "❌ an overlapping cleanup did not skip" >&2; exit 1; }

echo "  ✅ an overlapping cleanup skips instead of racing"
echo "✅ Hermes and development temp cleanup contract passed"
