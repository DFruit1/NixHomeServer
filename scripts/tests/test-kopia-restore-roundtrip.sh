#!/usr/bin/env bash

set -euo pipefail

for tool in cmp diff jq kopia readlink; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "❌ Missing restore-test dependency: $tool" >&2
    exit 1
  fi
done

test_root="$(mktemp -d)"
cleanup() {
  rm -rf "$test_root"
}
trap cleanup EXIT

repository="$test_root/repository"
source_root="$test_root/source"
restore_root="$test_root/restored"
config_file="$test_root/repository.config"

mkdir -p "$repository" "$source_root/nested" "$test_root/cache" "$test_root/log"
printf 'NixHomeServer restore fixture\n' >"$source_root/important.txt"
printf '\x00\x01\x02\xffbinary\n' >"$source_root/nested/binary.dat"
printf 'target contents\n' >"$source_root/nested/target.txt"
ln -s nested/target.txt "$source_root/link-to-target"
chmod 0640 "$source_root/important.txt"

export KOPIA_PASSWORD='nixhomeserver-restore-roundtrip-test'
export KOPIA_CONFIG_PATH="$config_file"
export KOPIA_CACHE_DIRECTORY="$test_root/cache"
export KOPIA_LOG_DIR="$test_root/log"
export KOPIA_CHECK_FOR_UPDATES=false
export KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=false

kopia repository create filesystem \
  --path "$repository" \
  --disable-file-logging \
  --no-persist-credentials >/dev/null
kopia snapshot create "$source_root" \
  --disable-file-logging \
  --no-progress >/dev/null

snapshot_json="$(kopia snapshot list "$source_root" --json --disable-file-logging)"
root_object="$(jq -er '.[0].rootEntry.obj | select(type == "string" and length > 0)' <<<"$snapshot_json")"

# Reconnect from a fresh client configuration so this checks repository
# recovery, not merely reuse of the snapshotting process's local state.
kopia repository disconnect --disable-file-logging >/dev/null
rm -f "$config_file"
rm -rf "$test_root/cache"
mkdir "$test_root/cache"
kopia repository connect filesystem \
  --path "$repository" \
  --disable-file-logging \
  --no-persist-credentials >/dev/null
kopia snapshot restore "$root_object" "$restore_root" \
  --disable-file-logging \
  --no-progress >/dev/null

diff --recursive --no-dereference "$source_root" "$restore_root"
cmp "$source_root/nested/binary.dat" "$restore_root/nested/binary.dat"
[[ "$(readlink "$restore_root/link-to-target")" == 'nested/target.txt' ]]
[[ "$(stat -c '%a' "$restore_root/important.txt")" == 640 ]]

echo "✅ Kopia snapshot reconnect-and-restore round trip passed."
