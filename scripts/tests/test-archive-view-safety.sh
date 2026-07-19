#!/usr/bin/env bash

set -euo pipefail

# shellcheck source=scripts/tests/test-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools nix nix-store python3 sha256sum tar unshare

run_behavior=1
if [[ -z "${NIXHOMESERVER_ARCHIVE_VIEW_HELPER:-}" \
  && "${NIXHOMESERVER_SKIP_NESTED_BUILDS:-0}" == "1" ]]; then
  run_behavior=0
fi

if ((run_behavior == 1)); then
  host="$(test_default_host)"
  if [[ -n "${NIXHOMESERVER_ARCHIVE_VIEW_HELPER:-}" ]]; then
    helper="$NIXHOMESERVER_ARCHIVE_VIEW_HELPER"
    helper_output="${helper%/bin/files-archive-view-helper}"
  else
    helper_attr=".#nixosConfigurations.${host}.config.systemd.services.files-archives-sync.environment"
    helper="$(nix eval --raw "${helper_attr}.ARCHIVE_VIEW_HELPER")"
    helper_drv="$(
      nix eval --raw "${helper_attr}.ARCHIVE_VIEW_HELPER" \
        --apply 'helper: builtins.head (builtins.attrNames (builtins.getContext helper))'
    )"
    helper_output="$(nix-store --realise "$helper_drv")"
  fi

case "$helper" in
  "$helper_output"/bin/files-archive-view-helper) ;;
  *)
    echo "❌ Evaluated archive helper does not belong to its declared derivation." >&2
    exit 1
    ;;
esac

  export ARCHIVE_VIEW_TEST_HELPER="$helper"

# A user namespace gives the behavioral test UID 0 and root-owned test files
# without touching any real host files or requiring sudo.
  unshare -Ur -- bash -s <<'ARCHIVE_TEST'
set -euo pipefail

helper="$ARCHIVE_VIEW_TEST_HELPER"
policy=extract-safe-single-root-v3
suffix=.contents
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT
archive_root="$test_root/archives"
outside_root="$test_root/outside"
state_root="$test_root/state"
mkdir -p "$archive_root" "$outside_root" "$state_root"

archive_hash() {
  printf '%s' "$policy:$1" | sha256sum | cut -d ' ' -f1
}

reconcile() {
  local source="$1"
  local maximum_archive="${2:-1048576}"
  local maximum_expanded="${3:-1048576}"
  local maximum_entries="${4:-100}"
  local hash
  hash="$(archive_hash "$source")"
  "$helper" reconcile \
    --source "$source" \
    --root "$archive_root" \
    --suffix "$suffix" \
    --state "$state_root/$hash.json" \
    --archive-hash "$hash" \
    --policy "$policy" \
    --maximum-archive-bytes "$maximum_archive" \
    --maximum-expanded-bytes "$maximum_expanded" \
    --maximum-entries "$maximum_entries" \
    --timeout-seconds 15
}

remove_stale() {
  local source="$1"
  local hash
  hash="$(archive_hash "$source")"
  "$helper" remove \
    --source "$source" \
    --root "$archive_root" \
    --suffix "$suffix" \
    --state "$state_root/$hash.json" \
    --archive-hash "$hash" \
    --policy "$policy"
}

assert_refused() {
  if "$@"; then
    echo "❌ Unsafe archive operation unexpectedly succeeded: $*" >&2
    exit 1
  fi
}

make_single_root_tar() {
  local archive="$1"
  local content="$2"
  local payload="$test_root/payload"
  rm -rf -- "$payload"
  mkdir -p "$payload/root"
  printf '%s' "$content" > "$payload/root/content.txt"
  ln -s /etc/passwd "$payload/root/external-link"
  tar -cf "$archive" -C "$payload" root
}

# A final-component source symlink and a symlinked ancestor are both rejected;
# neither can trick root into reading an archive outside the allowed root.
make_single_root_tar "$outside_root/outside.tar" outside
ln -s "$outside_root/outside.tar" "$archive_root/source-link.tar"
assert_refused reconcile "$archive_root/source-link.tar"
[[ ! -e "$archive_root/source-link.tar.contents" ]]

mkdir -p "$outside_root/subdir"
cp "$outside_root/outside.tar" "$outside_root/subdir/nested.tar"
ln -s "$outside_root/subdir" "$archive_root/linked-parent"
assert_refused reconcile "$archive_root/linked-parent/nested.tar"
[[ ! -e "$archive_root/linked-parent/nested.tar.contents" ]]

outside_hash="$(archive_hash "$outside_root/outside.tar")"
assert_refused "$helper" reconcile \
  --source "$outside_root/outside.tar" \
  --root "$archive_root" \
  --suffix "$suffix" \
  --state "$state_root/$outside_hash.json" \
  --archive-hash "$outside_hash" \
  --policy "$policy" \
  --maximum-archive-bytes 1048576 \
  --maximum-expanded-bytes 1048576 \
  --maximum-entries 100 \
  --timeout-seconds 15

# A same-named directory made by a user must be preserved, even if root-owned in
# this isolated namespace.  Only the unforgeable managed marker authorizes it.
make_single_root_tar "$archive_root/preexisting.tar" payload
mkdir "$archive_root/preexisting.tar.contents"
printf 'keep me' > "$archive_root/preexisting.tar.contents/sentinel"
assert_refused reconcile "$archive_root/preexisting.tar"
[[ "$(< "$archive_root/preexisting.tar.contents/sentinel")" == "keep me" ]]

# Safe publication strips one common root, removes archive-member symlinks, emits
# root-owned provenance/state, and makes the view read-only.
make_single_root_tar "$archive_root/safe.tar" first
reconcile "$archive_root/safe.tar"
safe_view="$archive_root/safe.tar.contents"
safe_hash="$(archive_hash "$archive_root/safe.tar")"
[[ "$(< "$safe_view/content.txt")" == "first" ]]
[[ ! -e "$safe_view/external-link" ]]
[[ -f "$safe_view/.nixhomeserver-archive-view" ]]
[[ "$(stat -c %u "$safe_view")" == 0 ]]
[[ "$(stat -c %u "$safe_view/.nixhomeserver-archive-view")" == 0 ]]
[[ "$(stat -c %a "$safe_view")" == 555 ]]
[[ "$(stat -c %a "$safe_view/content.txt")" == 444 ]]
python3 - "$safe_view/.nixhomeserver-archive-view" "$state_root/$safe_hash.json" <<'PY'
import json
import re
import sys

marker = json.load(open(sys.argv[1], encoding="utf-8"))
state = json.load(open(sys.argv[2], encoding="utf-8"))
assert marker["kind"] == "view"
assert re.fullmatch(r"[0-9a-f]{64}", marker["token"])
assert len(state["sourceSignature"]) == 8
assert re.fullmatch(r"[0-9a-f]{64}", state["sha256"])
PY

# State alone is not proof that the materialized view still exists.  If only the
# managed view is deleted, reconciliation must rebuild it from the unchanged
# archive instead of incorrectly taking the state-signature fast path.
rm -rf -- "$safe_view"
[[ -f "$state_root/$safe_hash.json" ]]
reconcile "$archive_root/safe.tar" > "$test_root/recreate-missing-view.log"
[[ "$(< "$safe_view/content.txt")" == "first" ]]
[[ -f "$safe_view/.nixhomeserver-archive-view" ]]
grep -Fq 'Published managed archive view:' "$test_root/recreate-missing-view.log"

# Refresh uses unpredictable internal names.  Old predictable sibling names are
# never touched, and the managed view is replaced only after provenance checks.
mkdir "$archive_root/safe.tar.contents.previous.12345"
printf preserved > "$archive_root/safe.tar.contents.previous.12345/sentinel"
mkdir "$archive_root/safe.tar.contents.extracting.12345"
printf preserved > "$archive_root/safe.tar.contents.extracting.12345/sentinel"
make_single_root_tar "$archive_root/safe.tar" second
reconcile "$archive_root/safe.tar"
[[ "$(< "$safe_view/content.txt")" == "second" ]]
[[ "$(< "$archive_root/safe.tar.contents.previous.12345/sentinel")" == preserved ]]
[[ "$(< "$archive_root/safe.tar.contents.extracting.12345/sentinel")" == preserved ]]

# Traversal is rejected before extraction and cannot escape the staging root.
python3 - "$archive_root/traversal.tar" <<'PY'
import io
import tarfile
import sys

with tarfile.open(sys.argv[1], "w") as archive:
    member = tarfile.TarInfo("../escaped")
    payload = b"escape"
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
assert_refused reconcile "$archive_root/traversal.tar"
[[ ! -e "$test_root/escaped" ]]
[[ ! -e "$archive_root/traversal.tar.contents" ]]

# A symlink member followed by a file below that link must not pivot extraction
# outside the descriptor-held staging directory.
python3 - "$archive_root/symlink-pivot.tar" "$outside_root" <<'PY'
import io
import tarfile
import sys

with tarfile.open(sys.argv[1], "w") as archive:
    root = tarfile.TarInfo("root/")
    root.type = tarfile.DIRTYPE
    archive.addfile(root)
    pivot = tarfile.TarInfo("root/pivot")
    pivot.type = tarfile.SYMTYPE
    pivot.linkname = sys.argv[2]
    archive.addfile(pivot)
    member = tarfile.TarInfo("root/pivot/escaped")
    payload = b"escape"
    member.size = len(payload)
    archive.addfile(member, io.BytesIO(payload))
PY
assert_refused reconcile "$archive_root/symlink-pivot.tar"
[[ ! -e "$outside_root/escaped" ]]
[[ ! -e "$archive_root/symlink-pivot.tar.contents" ]]

# Both the declared expanded-size preflight and entry-count ceiling fail closed.
large_payload="$test_root/large-payload"
mkdir -p "$large_payload/root"
dd if=/dev/zero of="$large_payload/root/large.bin" bs=8192 count=1 status=none
tar -cf "$archive_root/expanded.tar" -C "$large_payload" root
assert_refused reconcile "$archive_root/expanded.tar" 1048576 1024 100
[[ ! -e "$archive_root/expanded.tar.contents" ]]
assert_refused reconcile "$archive_root/expanded.tar" 512 1048576 100

entries_payload="$test_root/entries-payload"
mkdir -p "$entries_payload/root"
touch "$entries_payload/root/one" "$entries_payload/root/two" "$entries_payload/root/three"
tar -cf "$archive_root/entries.tar" -C "$entries_payload" root
assert_refused reconcile "$archive_root/entries.tar" 1048576 1048576 2
[[ ! -e "$archive_root/entries.tar.contents" ]]

# Stale cleanup removes only a proven view.  A similarly named user directory and
# predictable siblings survive, including when no source archive exists.
rm "$archive_root/safe.tar"
remove_stale "$archive_root/safe.tar"
[[ ! -e "$safe_view" ]]
[[ -e "$archive_root/safe.tar.contents.previous.12345/sentinel" ]]
[[ -e "$archive_root/safe.tar.contents.extracting.12345/sentinel" ]]
[[ ! -e "$state_root/$safe_hash.json" ]]

mkdir "$archive_root/ghost.tar.contents"
printf 'do not remove' > "$archive_root/ghost.tar.contents/sentinel"
assert_refused remove_stale "$archive_root/ghost.tar"
[[ "$(< "$archive_root/ghost.tar.contents/sentinel")" == "do not remove" ]]

# Every failed extraction cleaned only its own proven random stage.
if find "$archive_root" -type d -name '.nixhomeserver-archive-stage-*' -print -quit | grep -q .; then
  echo "❌ A failed archive operation leaked a managed staging directory." >&2
  exit 1
fi
ARCHIVE_TEST
fi

require_fixed modules/files/archives.nix 'O_NOFOLLOW' \
  "archive sources and managed paths must be opened without following symlinks"
require_fixed modules/files/archives.nix 'renameat2' \
  "archive publication must use an atomic no-replace operation"
require_fixed modules/files/archives.nix '.nixhomeserver-archive-view' \
  "managed archive views must carry provenance"
forbid_match modules/files/archives.nix 'view_path\.previous\.\$\$|view_path\.extracting\.\$\$' \
  "archive reconciliation must not delete predictable sibling paths"

echo "✅ Archive-view source, extraction, publication, cleanup, and limit tests passed."
