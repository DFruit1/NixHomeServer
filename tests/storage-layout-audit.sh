#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools mktemp rg

echo "ℹ️ Checking storage layout audit behavior…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p \
  "$tmpdir/mnt/data/media/documents" \
  "$tmpdir/mnt/data/media/photos" \
  "$tmpdir/mnt/data/kiwix" \
  "$tmpdir/mnt/data/users" \
  "$tmpdir/mnt/data/shared" \
  "$tmpdir/var/lib/kanidm" \
  "$tmpdir/var/lib/jellyfin" \
  "$tmpdir/persist/appdata/mail-archive-ui" \
  "$tmpdir/mnt/data/appdata" \
  "$tmpdir/mnt/data/media/audio" \
  "$tmpdir/mnt/data/media/books" \
  "$tmpdir/mnt/data/media/video"

clean_output="$(
  AUDIT_STORAGE_LAYOUT_ROOT_PREFIX="$tmpdir" \
    scripts/audit-storage-layout.sh
)"
require_match <(printf '%s\n' "$clean_output") '^✅ retired root empty: /mnt/data/appdata$' \
  "The storage layout audit must report empty retired roots."
require_match <(printf '%s\n' "$clean_output") '^✅ active payload root: /mnt/data/shared \(present\)$' \
  "The storage layout audit must report active payload roots."
require_match <(printf '%s\n' "$clean_output") '^✅ active app state root: /var/lib/kanidm \(present\)$' \
  "The storage layout audit must report active app-state roots."

printf 'stale\n' >"$tmpdir/mnt/data/media/books/leftover.txt"

set +e
dirty_output="$(
  AUDIT_STORAGE_LAYOUT_ROOT_PREFIX="$tmpdir" \
    scripts/audit-storage-layout.sh 2>&1
)"
dirty_status=$?
set -e
require_json_equal "$dirty_status" "1" \
  "The storage layout audit must fail when a retired root still contains data."
require_match <(printf '%s\n' "$dirty_output") '^❌ retired root non-empty: /mnt/data/media/books$' \
  "The storage layout audit must identify non-empty retired roots."

echo "✅ Storage layout audit tests passed."
