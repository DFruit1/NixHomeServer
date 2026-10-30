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
ensure_tools flock

root="$(mktemp -d /tmp/nixhomeserver-test-temp-cleanup.XXXXXXXX)"
trap 'chmod -R u+rwX "$root" 2>/dev/null || true; rm -rf "$root"' EXIT

home="$root/home"
repo="$root/repo"
tmp="$root/tmp"
state="$root/state"
mkdir -p "$home" "$repo" "$tmp" "$state"

mkdir -p "$root/scripts/admin"
cp "$TESTS_REPO_ROOT/scripts/admin/temp-cleanup.sh" "$root/scripts/admin/"
cleanup="$root/scripts/admin/temp-cleanup.sh"

backdate() { touch -d '40 days ago' -- "$@"; }
backdate_tree() { # set an old mtime after its contents exist
  touch -d '40 days ago' -- "$@"
}

# --- generated output safety --------------------------------------------------

mkdir -p "$repo/output/old-cache" "$repo/output/new-cache"
: >"$repo/output/old-cache/data"
: >"$repo/output/new-cache/data"
backdate "$repo/output/old-cache/data"; backdate "$repo/output/old-cache"

# A cached database snapshot and an encrypted archive are high-value data.
mkdir -p "$repo/output/db-snapshot"
: >"$repo/output/db-snapshot/state.db"
backdate "$repo/output/db-snapshot/state.db"; backdate "$repo/output/db-snapshot"
: >"$repo/output/evidence.age"
backdate "$repo/output/evidence.age"

# A cached checkout is not temp data.
mkdir -p "$repo/output/cached-repo/.git"
: >"$repo/output/cached-repo/.git/HEAD"
backdate "$repo/output/cached-repo/.git/HEAD"; backdate_tree "$repo/output/cached-repo"

# A symlink is never followed or removed; its target lives outside every root.
mkdir -p "$home/valuable-data"
: >"$home/valuable-data/keep"
ln -s "$home/valuable-data" "$repo/output/old-link"
touch -h -d '40 days ago' -- "$repo/output/old-link"

# --- tmp and repository scratch ---------------------------------------------

mkdir -p "$tmp/nixhomeserver-old" "$tmp/nixhomeserver-new" "$tmp/unrelated-old"
: >"$tmp/nixhomeserver-old/data"; : >"$tmp/unrelated-old/data"
backdate_tree "$tmp/nixhomeserver-old"
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
  HOME="$home" TEMP_CLEANUP_REPO_PATH="$repo" \
    TEMP_CLEANUP_TMP_DIR="$tmp" TEMP_CLEANUP_STATE_DIR="$state" \
    bash "$cleanup" "$@"
}

echo "▶ Development temp cleanup"

# --- dry run never deletes ---------------------------------------------------

dry="$(run_cleanup)"
grep -q 'would remove (tmp): .*/nixhomeserver-old' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected aged tooling scratch in /tmp to be classified" >&2; exit 1; }
grep -q 'would remove (repo scratch): .*/.tmp/old-task' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected aged repository scratch to be classified" >&2; exit 1; }
grep -q 'would remove (repo output): .*/output' <<<"$dry" \
  || { echo "$dry" >&2; echo "❌ expected aged repository output to be classified" >&2; exit 1; }
grep -q 'unrelated-old' <<<"$dry" \
  && { echo "$dry" >&2; echo "❌ an unrelated /tmp directory was classified" >&2; exit 1; }
[[ -d "$repo/output/old-cache" ]] || { echo "❌ dry run deleted a cache entry" >&2; exit 1; }

echo "  ✅ dry run classifies only allowlisted, aged, unprotected entries"

# --- apply deletes exactly the safe entries ---------------------------------

run_cleanup --apply >/dev/null

[[ ! -e "$repo/output/old-cache" ]] || { echo "❌ aged cache entry was not removed" >&2; exit 1; }
[[ -e "$repo/output/evidence.age" ]] || { echo "❌ encrypted evidence archive was deleted" >&2; exit 1; }
[[ -d "$repo/output/db-snapshot" ]] || { echo "❌ cached database snapshot was deleted" >&2; exit 1; }
[[ -d "$repo/output/cached-repo" ]] || { echo "❌ cached git checkout was deleted" >&2; exit 1; }
[[ -L "$repo/output/old-link" && -d "$home/valuable-data" ]] \
  || { echo "❌ a symlink or its target was deleted" >&2; exit 1; }
[[ -d "$repo/output/new-cache" ]] || { echo "❌ a recent cache entry was deleted" >&2; exit 1; }
[[ ! -e "$tmp/nixhomeserver-old" && -e "$tmp/nixhomeserver-new" && -e "$tmp/unrelated-old" ]] \
  || { echo "❌ /tmp cleanup was not limited to aged tooling scratch" >&2; exit 1; }
[[ ! -e "$repo/.tmp/old-task" && -d "$repo/.tmp/new-task" ]] \
  || { echo "❌ repository scratch retention was not applied exactly" >&2; exit 1; }
[[ ! -e "$repo/output/old.png" && ! -e "$repo/test-results/old.json" && ! -e "$repo/playwright-report/old.html" ]] \
  || { echo "❌ aged generated output was not removed" >&2; exit 1; }

echo "  ✅ apply removes only aged, unprotected entries and keeps valuable data"

# --- missing roots are harmless ---------------------------------------------

out="$(HOME="$home" TEMP_CLEANUP_REPO_PATH="$root/absent" \
  TEMP_CLEANUP_TMP_DIR="$root/absent" TEMP_CLEANUP_STATE_DIR="$state" bash "$cleanup" --apply)"
grep -q 'Removed: *0' <<<"$out" \
  || { echo "$out" >&2; echo "❌ a missing root was not treated as empty" >&2; exit 1; }

echo "  ✅ missing roots are skipped without failure"

# --- overlapping runs skip ---------------------------------------------------

exec 9>"$state/temp-cleanup.lock"
flock 9
lock_out="$(HOME="$home" TEMP_CLEANUP_REPO_PATH="$repo" \
  TEMP_CLEANUP_TMP_DIR="$tmp" TEMP_CLEANUP_STATE_DIR="$state" bash "$cleanup" 2>&1)"
exec 9>&-
grep -q 'Another temp cleanup holds the lock; skipping' <<<"$lock_out" \
  || { echo "$lock_out" >&2; echo "❌ an overlapping cleanup did not skip" >&2; exit 1; }

echo "  ✅ an overlapping cleanup skips instead of racing"
echo "✅ Development temp cleanup contract passed"
