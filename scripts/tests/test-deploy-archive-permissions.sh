#!/usr/bin/env bash
# Offline positive DAC proof using the production namespace and stamp writer.
# All ownership/mount changes are isolated in user/mount namespaces.
# Requires subordinate uid/gid mappings and unprivileged user namespaces.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${1:-}" != "--inside-userns" ]]; then
  exec unshare --user --map-auto --map-root-user --mount \
    bash "$0" --inside-userns
fi

export TARGET_HOST=admin@test.invalid BUILD_HOST=admin@test.invalid ACTION=test
export HOSTNAME_ARG=test-host DEBUG_MODE=false BUILD_MODE=remote
export LOCAL_BUILD_SLOTS=0 REMOTE_BUILD_SLOTS=auto LOCAL_BUILD_CORES=0 REMOTE_BUILD_CORES=0
export HOST_PLATFORM=x86_64-linux BUILDER_SSH_PUBLIC_KEY=fixture-key
source "$repo_root/scripts/helpers/deploy-executor.sh"
fixture="$(mktemp -d)"
trap 'umount /var/lib; rm -rf "$fixture"' EXIT
chmod 0755 "$fixture"
cp "$repo_root/scripts/helpers/deploy-archive-cleanup.sh" "$fixture/helper.sh"
chmod 0644 "$fixture/helper.sh"
# Binding over /var/lib inside this mount namespace also avoids the host's
# private TMPDIR ancestry and exercises the real absolute production default.
mount --bind "$fixture" /var/lib
state=/var/lib/nixhomeserver-deploy
archives=/var/lib/nixhomeserver-deploy-archives
mkdir "$state" "$archives" "$state/archive-staging"
chmod 0700 "$state" "$archives" "$state/archive-staging"
chown 1:1 "$archives" "$state/archive-staging"
printf 'private stamp\n' >"$state/stamp"
chmod 0600 "$state/stamp"
as_admin() { setpriv --reuid 1 --regid 1 --clear-groups "$@"; }
assert_private_state() {
  [[ "$(stat -c '%a:%u:%g' "$state")" == '700:0:0' ]]
  [[ "$(stat -c '%a:%u:%g' "$archives")" == '700:1:1' ]]
  if as_admin cat "$state/stamp"; then
    echo 'FAIL: non-root caller read root-only stamp' >&2; exit 1
  fi
  if as_admin test -x "$state"; then
    echo 'FAIL: non-root caller traversed root-only state' >&2; exit 1
  fi
}
assert_stage_remove() {
  local archive
  archive="$(as_admin env -u NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE \
    bash /var/lib/helper.sh stage nixhomeserver-deploy)"
  [[ "$archive" == "$archives/"* ]]
  [[ "$(stat -c '%a:%u:%g' "$archive")" == '600:1:1' ]]
  as_admin env -u NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE \
    bash /var/lib/helper.sh remove "$archive"
  [[ ! -e "$archive" ]]
}
assert_private_state
assert_stage_remove
echo 'ok: non-root SSH-user stand-in stages/removes 0600 owned archives in the production 0700 sibling'
# Negative control: the previous child layout remains inaccessible.
if as_admin env NIXHOMESERVER_DEPLOY_ARCHIVE_NAMESPACE="$state/archive-staging" \
  bash /var/lib/helper.sh stage nixhomeserver-deploy; then
  echo 'FAIL: non-root caller staged below root-only state' >&2; exit 1
fi

# Execute the actual stamp writer, replacing only its remote sudo transport.
# Namespace uid 0 is not host root; no host state or privileges are changed.
sudo() { "$@"; }
export -f sudo
target_command() { bash -c "$1"; }
deploy_state_dir="$state"
test_stamp_path="$state/stamp"
test_gcroot_dir=/var/lib/gcroots
test_gcroot_path="$test_gcroot_dir/test-host"
deploy_lock_dir="$state/transactions/test-host"
mkdir -p "$deploy_lock_dir"
printf '%s' "$deploy_lock_token" >"$deploy_lock_dir/owner"
deploy_lock_acquired=true
source_hash=sha256-Zml4dHVyZQ==
write_test_stamp /nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-fixture-system
[[ "$(stat -c '%a:%u:%g' "$test_stamp_path")" == '600:0:0' ]]
assert_private_state
assert_stage_remove
echo 'ok: real stamp writer reasserts root-only state/stamp without blocking sibling staging/removal'
