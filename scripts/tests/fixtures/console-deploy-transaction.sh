#!/usr/bin/env bash
# Console-route deploy transaction fixture.
#
# The whole point of `deploy.sh --console` is that a deploy whose activation
# drops the local admin's passwordless sudo can still finish its own
# transaction: the activation removes the grant, and every later privileged step
# (health gates, stamp write, rollback cancellation, lock release, boot commit)
# still has to succeed. That claim cannot be verified by inspecting the routing
# predicate, so this fixture runs the real deploy-executor.sh transaction with
# only the external operations mocked:
#
#   * a simulated Nix store, boot profile and /run/current-system, created in a
#     private mount namespace, so the real host is never touched;
#   * a mock `sudo` that records every privileged call together with the
#     policy in force at that moment, and refuses to authenticate once the
#     passwordless grant is gone unless the caller is already root;
#   * a mock `ssh` that fails loudly, because in console mode the target is
#     this machine and any SSH hop is the regression this guards against;
#   * a mock `systemctl` that drops the passwordless grant at activation, i.e.
#     effective authorization changes mid-transaction exactly as a real
#     bootstrap-to-restricted transition does.
#
# Usage: run_console_deploy_transaction <fake-uid> <work-dir>
# Prints EXECUTOR_STATUS / LOCK_PRESENT / STAMP_PRESENT and leaves one ordered
# event log in <work-dir>/events. Exits with the executor's own status.

set -euo pipefail

fake_uid="$1"
work_dir="$2"
mock_bin="$work_dir/mock-bin"

console_toplevel="/nix/store/00000000000000000000000000000000-console-fixture"
console_nix_env="/nix/store/11111111111111111111111111111111-nix-fixture/bin/nix-env"

mount -t tmpfs -o size=32G tmpfs /nix
mount -t tmpfs tmpfs /run
mkdir -p \
  "$console_toplevel/bin" \
  "$console_toplevel/sw/bin" \
  "$(dirname "$console_nix_env")" \
  /nix/var/nix/profiles \
  /nix/var/nix/gcroots/nixhomeserver-tested \
  /run/systemd/system

cat >"$console_toplevel/bin/switch-to-configuration" <<'CONSOLE_STC'
#!/usr/bin/env bash
printf 'switch-to-configuration %s uid=%s\n' "$*" "$(id -u)" >>"$TEST_EVENT_LOG"
exit 0
CONSOLE_STC
cat >"$console_toplevel/sw/bin/homepage-canary-assert" <<'CONSOLE_CANARY'
#!/usr/bin/env bash
printf 'canary-assert uid=%s\n' "$(id -u)" >>"$TEST_EVENT_LOG"
exit 0
CONSOLE_CANARY
cat >"$console_nix_env" <<'CONSOLE_NIX_ENV'
#!/usr/bin/env bash
printf 'nix-env %s uid=%s\n' "$*" "$(id -u)" >>"$TEST_EVENT_LOG"
exit 0
CONSOLE_NIX_ENV
chmod +x \
  "$console_toplevel/bin/switch-to-configuration" \
  "$console_toplevel/sw/bin/homepage-canary-assert" \
  "$console_nix_env"
ln -sfn "$console_toplevel" /nix/var/nix/profiles/system
ln -sfn "$console_toplevel" /run/current-system

mkdir -p "$mock_bin"

export TEST_FAKE_UID="$fake_uid"
export TEST_TOPLEVEL="$console_toplevel"
export TEST_PRIVILEGE_STATE="$work_dir/policy"
export TEST_EVENT_LOG="$work_dir/events"
printf 'bootstrap-nopasswd\n' >"$TEST_PRIVILEGE_STATE"
: >"$TEST_EVENT_LOG"

cat >"$mock_bin/id" <<'CONSOLE_ID'
#!/usr/bin/env bash
case "${1:-}" in
  -u) printf '%s\n' "$TEST_FAKE_UID" ;;
  *) printf 'uid=%s\n' "$TEST_FAKE_UID" ;;
esac
CONSOLE_ID

cat >"$mock_bin/ssh" <<'CONSOLE_SSH'
#!/usr/bin/env bash
printf 'ssh hop used in console mode: %s\n' "$*" >>"$TEST_EVENT_LOG"
exit 97
CONSOLE_SSH

cat >"$mock_bin/sudo" <<'CONSOLE_SUDO'
#!/usr/bin/env bash
# Record the call, the caller's identity and the policy in force, then enforce
# the contract: a non-root caller only authenticates while the passwordless
# grant exists. A transaction that keeps needing sudo after activation has
# dropped the grant therefore fails here exactly as it would on a real host.
# Every mocked operation appends to one ordered log, so the test can compare
# what happened before and after the activation within a single sequence.
policy="$(cat "$TEST_PRIVILEGE_STATE" 2>/dev/null || printf 'none')"
printf 'sudo %s uid=%s policy=%s\n' "$*" "$(id -u)" "$policy" >>"$TEST_EVENT_LOG"
if [[ "$(id -u)" != "0" && "$policy" != "bootstrap-nopasswd" ]]; then
  echo "sudo: a terminal is required to read the password" >&2
  exit 1
fi
exec "$@"
CONSOLE_SUDO

cat >"$mock_bin/systemctl" <<'CONSOLE_SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$TEST_EVENT_LOG"
case "${1:-}" in
  --failed)
    exit 0
    ;;
  start)
    if [[ "$*" == *nixos-detached-* ]]; then
      # A real activation lands here. This is where the restricted policy
      # becomes effective and the passwordless grant disappears.
      printf 'password-authenticated\n' >"$TEST_PRIVILEGE_STATE"
      printf 'grant-dropped\n' >>"$TEST_EVENT_LOG"
    fi
    exit 0
    ;;
  show)
    case "$*" in
      *LoadState*) printf 'not-found\n' ;;
      *Result*) printf 'success\n' ;;
      *ExecMainStatus*) printf '0\n' ;;
      *) printf 'inactive\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
CONSOLE_SYSTEMCTL

cat >"$mock_bin/nix" <<'CONSOLE_NIX'
#!/usr/bin/env bash
case "$*" in
  *nixos-rebuild*)
    printf 'nixos-rebuild\n' >>"$TEST_EVENT_LOG"
    printf '%s\n' "$TEST_TOPLEVEL"
    ;;
  *"hash path"*) printf 'sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n' ;;
  *nixosConfigurations*config*)
    printf '{"drvPath":"/nix/store/00000000000000000000000000000000-console-fixture.drv","homepage":true}\n'
    ;;
  "config show") printf 'sandbox-build-dir = /\n' ;;
  *)
    printf 'unexpected nix call: %s\n' "$*" >&2
    exit 1
    ;;
esac
CONSOLE_NIX

cat >"$mock_bin/curl" <<'CONSOLE_CURL'
#!/usr/bin/env bash
# Satisfies the public-route health gate without any network access.
output=""
headers=""
while (($# > 0)); do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    --dump-header) headers="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$output" ]] && printf 'ok\n' >"$output"
[[ -n "$headers" ]] && : >"$headers"
printf '200'
CONSOLE_CURL

chmod +x "$mock_bin"/*

export PATH="$mock_bin:/usr/bin:/bin"
export NIX_CONFIG="experimental-features = nix-command flakes
accept-flake-config = true"
export PUBLIC_ROUTE_CHECK_URLS="https://console-fixture.invalid/"

# A console deploy targets this machine, so the destination and build host are
# deliberately remote-looking: if routing ever fell back to SSH, the mock ssh
# would fail the transaction.
export TARGET_HOST="local-admin@198.51.100.7"
export BUILD_HOST="build-box@198.51.100.9"
export ACTION="test"
export HOSTNAME_ARG="console-fixture"
export DEBUG_MODE="false"
export BUILD_LOCALLY="false"
export CONSOLE_MODE="true"
export BUILD_MODE="local"
export LOCAL_BUILD_SLOTS="auto"
export REMOTE_BUILD_SLOTS="0"
export LOCAL_BUILD_CORES="0"
export REMOTE_BUILD_CORES="0"
export HOST_PLATFORM="x86_64-linux"
export BUILDER_SSH_PUBLIC_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyNotARealKey"

# shellcheck source=scripts/helpers/deploy-executor.sh
source scripts/helpers/deploy-executor.sh

# Redirect the transaction's real state into the fixture work directory so a
# run can never touch the host's deploy state, store or runtime unit directory
# (the store and /run are namespace-private anyway).
deploy_state_dir="$work_dir/deploy-state"
runtime_unit_script_dir="$deploy_state_dir/transactions/.unit-scripts"
deploy_lock_dir="$deploy_state_dir/transactions/console-fixture"
test_stamp_path="$deploy_state_dir/last-tested-console-fixture.stamp"
test_gcroot_dir="/nix/var/nix/gcroots/nixhomeserver-tested"
test_gcroot_path="$test_gcroot_dir/console-fixture"
runtime_unit_dir="/run/systemd/system"
deploy_target_path="$mock_bin:/usr/bin:/bin"
activation_poll_attempts=3
activation_poll_interval=0

status=0
deploy_main || status=$?
printf 'EXECUTOR_STATUS=%s\n' "$status"
printf 'LOCK_PRESENT=%s\n' "$([[ -d "$deploy_lock_dir" ]] && echo yes || echo no)"
printf 'STAMP_PRESENT=%s\n' "$([[ -f "$test_stamp_path" ]] && echo yes || echo no)"
exit "$status"
