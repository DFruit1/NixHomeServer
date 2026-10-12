#!/usr/bin/env bash
# A filesystem migration uses the existing rsync/coreutils tools rather than
# adding a daemon or a compiled backend. No model data is discarded.
set -euo pipefail

legacy="${1:?legacy directory required}"
archive="${2:?archive directory required}"
data_root="${3:?data mount required}"

fail() { echo "Bonsai model archive: $*" >&2; exit 1; }
[[ ! -L "$legacy" ]] || fail 'legacy directory is a symlink'
[[ -e "$legacy" ]] || exit 0
[[ -d "$legacy" ]] || fail 'legacy path is not a directory'
[[ "$(realpath -m -- "$legacy")" == "$legacy" ]] || fail 'legacy path traverses a symlink'
mountpoint -q "$data_root" || fail 'data pool is not mounted'
[[ "$archive" == "$data_root/bonsai/models" ]] || fail 'unexpected archive destination'
[[ "$(realpath -m -- "$archive")" == "$archive" ]] || fail 'archive path traverses a symlink'

# Ordering handles activation; this also protects a manual migration restart
# from an old model downloader that is still writing its .part file.
for producer in bonsai-model-prepare.service bonsai-llama.service; do
  producer_state="$(systemctl show "$producer" --property=ActiveState --value)"
  case "$producer_state" in
    inactive|failed) ;;
    *) fail "stop $producer before migrating legacy models (state: $producer_state)" ;;
  esac
done
[[ -z "$(find "$legacy" ! -type f ! -type d -print -quit)" ]] \
  || fail 'legacy models contain symlinks or special files'
if [[ -e "$archive" ]]; then
  [[ -d "$archive" ]] || fail 'archive path is not a directory'
  [[ -z "$(find "$archive" ! -type f ! -type d -print -quit)" ]] \
    || fail 'archive contains symlinks or special files'
fi

mkdir -p -- "$archive"
scratch="$(mktemp -d "$data_root/.nixhomeserver-model-archive.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
# Never overwrite an existing archive file. Conflicting or interrupted copies
# fail verification and leave ALL legacy files intact for operator recovery.
rsync --archive --ignore-existing --fsync --temp-dir="$scratch" -- "$legacy/" "$archive/"
differences="$(rsync --recursive --checksum --dry-run --itemize-changes -- "$legacy/" "$archive/")"
[[ -z "$differences" ]] || fail 'archive differs from legacy models; originals retained'
sync -f "$archive"

# Only after the complete tree is verified and flushed, remove source copies
# through rsync, which rechecks each file and fsyncs any required transfer.
rsync --archive --checksum --remove-source-files --fsync --temp-dir="$scratch" -- "$legacy/" "$archive/"
find "$legacy" -depth -type d -empty -delete
[[ ! -e "$legacy" ]] || fail 'legacy directory still has files; inspect before retrying'
echo "Archived Bonsai models at $archive"
