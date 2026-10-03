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
#   * a mock `systemctl` that executes a detached activation unit's ExecStart
#     line the way systemd does, and then drops the passwordless grant — so the
#     generation really changes and effective authorization really changes
#     mid-transaction, exactly as a bootstrap-to-restricted transition does;
#   * a mock `nix-env` that honours `--profile <p> --set <generation>`, so the
#     boot commit is observed from the resulting profile link instead of being
#     taken from the command line that claimed it.
#
# Each phase runs in its own deploy-executor.sh process, as a real --action test
# and a later --action switch are two separate guarded deploys, so the switch
# phase genuinely consumes the stamp, boot profile and lock state the test phase
# left on the simulated host.
#
# Usage: run_console_deploy_transaction <fake-uid> <work-dir> [phases...]
#   phases: space-separated executor actions to run in order (default:
#           "test switch"), i.e. a --action test transaction followed by the
#           --action switch transaction that consumes the stamp it wrote.
#   CONSOLE_FIXTURE_SOURCE_HASH_<phase> overrides the hash `nix hash path`
#           reports for one phase (CONSOLE_FIXTURE_SOURCE_HASH sets them all),
#           so a caller can prove the switch really validates the tested stamp
#           rather than trusting whatever hash it is handed.
#
# Prints one PHASE=<action> EXECUTOR_STATUS=..., PHASE=<action> BOOT_PROFILE=...
# and PHASE=<action> CURRENT_SYSTEM=... line per phase, then the final
# EXECUTOR_STATUS / LOCK_PRESENT / STAMP_PRESENT lines, and leaves one ordered
# event log per phase in <work-dir>/events-<action> plus <work-dir>/events as a
# copy of the test phase's log. Exits with the first failing phase's status.

set -euo pipefail

fake_uid="$1"
work_dir="$2"
shift 2
phases=("$@")
if ((${#phases[@]} == 0)); then
  phases=(test switch)
fi
mock_bin="$work_dir/mock-bin"

console_toplevel="/nix/store/00000000000000000000000000000000-console-fixture"
console_previous_toplevel="/nix/store/22222222222222222222222222222222-previous-generation-fixture"
console_nix_env="/nix/store/11111111111111111111111111111111-nix-fixture/bin/nix-env"

mount -t tmpfs -o size=32G tmpfs /nix
mount -t tmpfs tmpfs /run
# The executor's deploy state lives at its real production path. Rather than
# overriding that variable, map the production path onto the fixture directory
# inside this private namespace: a private /var/lib means creating the mount
# point cannot touch the host, and the bind makes the executor's own default
# resolve to the fixture work directory with no production code path altered.
mount -t tmpfs tmpfs /var/lib
mkdir -p /var/lib/nixhomeserver-deploy
mkdir -p "$work_dir/deploy-state"
mount --bind "$work_dir/deploy-state" /var/lib/nixhomeserver-deploy
mkdir -p \
  "$console_toplevel/bin" \
  "$console_toplevel/sw/bin" \
  "$console_previous_toplevel/bin" \
  "$console_previous_toplevel/sw/bin" \
  "$(dirname "$console_nix_env")" \
  /nix/var/nix/profiles \
  /nix/var/nix/gcroots/nixhomeserver-tested \
  /run/systemd/system

cat >"$console_toplevel/bin/switch-to-configuration" <<'CONSOLE_STC'
#!/usr/bin/env bash
# A real switch-to-configuration republishes /run/current-system for every mode
# and only `boot` also commits the boot profile. Reproducing that split is what
# lets the fixture observe the boot commit (profile link) instead of trusting
# the command line that claimed it.
toplevel="$(dirname "$(dirname "$(readlink -f "$0")")")"
printf 'switch-to-configuration %s uid=%s\n' "$*" "$(id -u)" >>"$TEST_EVENT_LOG"
ln -sfn "$toplevel" /run/current-system
if [[ "${1:-}" == "boot" ]]; then
  ln -sfn "$toplevel" /nix/var/nix/profiles/system
fi
printf 'current-system=%s\n' "$(readlink -f /run/current-system)" >>"$TEST_EVENT_LOG"
if [[ "${1:-}" == "boot" ]]; then
  printf 'boot-profile=%s\n' "$(readlink -f /nix/var/nix/profiles/system)" >>"$TEST_EVENT_LOG"
fi
exit 0
CONSOLE_STC
cat >"$console_previous_toplevel/bin/switch-to-configuration" <<'CONSOLE_PREVIOUS_STC'
#!/usr/bin/env bash
toplevel="$(dirname "$(dirname "$(readlink -f "$0")")")"
printf 'switch-to-configuration %s uid=%s\n' "$*" "$(id -u)" >>"$TEST_EVENT_LOG"
ln -sfn "$toplevel" /run/current-system
if [[ "${1:-}" == "boot" ]]; then
  ln -sfn "$toplevel" /nix/var/nix/profiles/system
fi
printf 'current-system=%s\n' "$(readlink -f /run/current-system)" >>"$TEST_EVENT_LOG"
if [[ "${1:-}" == "boot" ]]; then
  printf 'boot-profile=%s\n' "$(readlink -f /nix/var/nix/profiles/system)" >>"$TEST_EVENT_LOG"
fi
exit 0
CONSOLE_PREVIOUS_STC
cat >"$console_toplevel/sw/bin/homepage-canary-assert" <<'CONSOLE_CANARY'
#!/usr/bin/env bash
printf 'canary-assert uid=%s\n' "$(id -u)" >>"$TEST_EVENT_LOG"
exit 0
CONSOLE_CANARY
# The mock nix-env honours the one subcommand the boot-commit and rollback
# paths rely on: `--profile <path> --set <store-path>` repoints that profile,
# exactly as the real immutable entry point does. That makes a boot-commit
# assertion an observation of the resulting profile link rather than a restated
# command line, and keeps `--set <previous>` (restore_boot_generation) honest.
cat >"$console_nix_env" <<'CONSOLE_NIX_ENV'
#!/usr/bin/env bash
printf 'nix-env %s uid=%s\n' "$*" "$(id -u)" >>"$TEST_EVENT_LOG"
profile=""
generation=""
while (($# > 0)); do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --set) generation="$2"; shift 2 ;;
    *) shift ;;
  esac
done
if [[ -n "$profile" && -n "$generation" ]]; then
  ln -sfn "$generation" "$profile" || exit 1
  printf 'nix-env-profile=%s\n' "$(readlink -f "$profile")" >>"$TEST_EVENT_LOG"
fi
exit 0
CONSOLE_NIX_ENV
cat >"$console_previous_toplevel/sw/bin/homepage-canary-assert" <<'CONSOLE_PREVIOUS_CANARY'
#!/usr/bin/env bash
printf 'canary-assert uid=%s\n' "$(id -u)" >>"$TEST_EVENT_LOG"
exit 0
CONSOLE_PREVIOUS_CANARY
chmod +x \
  "$console_toplevel/bin/switch-to-configuration" \
  "$console_previous_toplevel/bin/switch-to-configuration" \
  "$console_toplevel/sw/bin/homepage-canary-assert" \
  "$console_previous_toplevel/sw/bin/homepage-canary-assert" \
  "$console_nix_env"
# The host starts on the previous generation in both slots, so the boot profile
# the switch transaction commits is provably not the one it started from.
ln -sfn "$console_previous_toplevel" /nix/var/nix/profiles/system
ln -sfn "$console_previous_toplevel" /run/current-system

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
# NixOS's /bin/sh is bash, and the guarded deploy relies on that: it renders
# unit files, rollback and lock-release commands with bash syntax ($'...'
# literals, printf %q) and then runs them through `/bin/sh -c <script>`. This
# test host's /bin/sh is dash, which would silently mangle that syntax into one
# literal line and make the fixture assert behaviour the real host never has.
# Re-dispatch those invocations to bash so the mock runs the commands the way
# NixOS does, leaving every other argument untouched.
if [[ "${1:-}" == "/bin/sh" || "${1:-}" == "/usr/bin/sh" ]]; then
  shift
  if [[ "${1:-}" == "-c" ]]; then
    shift
    exec bash -c "${1:-}"
  fi
  exec /bin/sh "$@"
fi
exec "$@"
CONSOLE_SUDO

cat >"$mock_bin/systemctl" <<'CONSOLE_SYSTEMCTL'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$TEST_EVENT_LOG"

# run_exec_start executes the ExecStart= line of a runtime unit file the way
# systemd would. Without it the detached activation would be an empty `start`,
# no switch-to-configuration would ever run, and the fixture would assert boot
# and activation behaviour that never happened.
run_exec_start() {
  local unit="$1"
  local unit_file="/run/systemd/system/${unit}.service"
  local exec_start="" line

  [[ -f "$unit_file" ]] || {
    echo "mock systemctl: ${unit}.service was not written to /run/systemd/system" >&2
    exit 1
  }
  while IFS= read -r line; do
    case "$line" in
      ExecStart=*) exec_start="${line#ExecStart=}" ;;
    esac
  done <"$unit_file"
  if [[ -z "$exec_start" ]]; then
    echo "mock systemctl: ${unit}.service has no ExecStart=" >&2
    exit 1
  fi
  printf 'systemctl-unit-exec %s %s uid=%s\n' "$unit" "$exec_start" "$(id -u)" >>"$TEST_EVENT_LOG"
  # NixOS's /bin/sh is bash, and the executor renders these commands with bash
  # syntax ($'...' literals, printf %q). Run the ExecStart through bash so the
  # mock does not silently differ from the real interpreter and, for instance,
  # swallow a unit whose command it failed to parse.
  # shellcheck disable=SC2086 # The rendered ExecStart is intentionally split.
  bash -c "$exec_start"
}

case "${1:-}" in
  --failed)
    exit 0
    ;;
  start)
    if [[ " $* " == *" nixos-detached-"*" "* ]]; then
      for unit in "$@"; do
        case "$unit" in
          nixos-detached-*)
            # A real activation lands here: the unit's ExecStart performs the
            # generation change, and the new system configuration is what
            # replaces the local admin's passwordless sudo grant. Doing both
            # here is what makes effective authorization change mid-transaction
            # exactly as a real bootstrap-to-restricted transition does.
            run_exec_start "$unit"
            printf 'password-authenticated\n' >"$TEST_PRIVILEGE_STATE"
            printf 'grant-dropped\n' >>"$TEST_EVENT_LOG"
            ;;
        esac
      done
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
  *"hash path"*) printf '%s\n' "${CONSOLE_FIXTURE_PHASE_SOURCE_HASH:-${CONSOLE_FIXTURE_SOURCE_HASH:-sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}}" ;;
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

# The simulated store's bin directory comes first, exactly as a real NixOS host
# resolves its immutable nix-env from the store: capture_previous_state walks
# `command -v nix-env` symlink chains to reach an immutable /nix/store entry, so
# the fixture must resolve the same way or that gate blocks for the wrong
# reason.
console_nix_env_bin="$(dirname "$console_nix_env")"
export PATH="${console_nix_env_bin}:${mock_bin}:/usr/bin:/bin"
export NIX_CONFIG="experimental-features = nix-command flakes
accept-flake-config = true"
export PUBLIC_ROUTE_CHECK_URLS="https://console-fixture.invalid/"

# A console deploy targets this machine, so the destination and build host are
# deliberately remote-looking: if routing ever fell back to SSH, the mock ssh
# would fail the transaction.
export TARGET_HOST="local-admin@198.51.100.7"
export BUILD_HOST="build-box@198.51.100.9"
export HOSTNAME_ARG="console-fixture"
# The executor requires ACTION at source time; the phase loop below reassigns it
# before each transaction, and deploy_main reads it dynamically.
export ACTION="test"
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

# Only the values the executor computes from wall-clock time or that must be
# fast for a test are overridden. The deploy-state, stamp, lock, GC-root and
# runtime-unit paths are deliberately left at their real production values: the
# namespace binds them onto the fixture work directory above, so the executor
# runs its genuine layout instead of a test-only rewrite of it.
#
# deploy_target_path is what the rendered rollback/lock/activation scripts
# export, so it must resolve the same commands the transaction resolves. It
# includes the simulated store bin dir for the immutable nix-env.
deploy_target_path="${console_nix_env_bin}:${mock_bin}:/usr/bin:/bin"
activation_poll_attempts=3
activation_poll_interval=0
export CONSOLE_FIXTURE_TARGET_PATH="$deploy_target_path"
export CONSOLE_FIXTURE_POLL_ATTEMPTS="$activation_poll_attempts"
export CONSOLE_FIXTURE_POLL_INTERVAL="$activation_poll_interval"

status=0
first_phase=""
last_phase=""
final_lock_present="unknown"
final_stamp_present="unknown"

# Each phase is a fresh deploy transaction against the same simulated host: a
# fresh lock token, fresh runtime units, and its own event log. Later phases see
# the deploy state the earlier ones left behind — in particular the stamp and
# the committed boot generation — which is what makes the switch phase a real
# "consume what the test proved" run rather than a second isolated test.
for phase in "${phases[@]}"; do
  case "$phase" in
    test|switch) ;;
    *)
      echo "fixture: unsupported phase '${phase}'" >&2
      exit 2
      ;;
  esac
  ACTION="$phase"
  export ACTION

  TEST_EVENT_LOG="$work_dir/events-$phase"
  : >"$TEST_EVENT_LOG"
  export TEST_EVENT_LOG

  # The repository hash this phase's `nix hash path` reports. A caller can
  # override it per phase to prove the switch really validates the stamp rather
  # than trusting whatever hash it is handed.
  phase_hash_var="CONSOLE_FIXTURE_SOURCE_HASH_${phase}"
  phase_hash="${!phase_hash_var:-${CONSOLE_FIXTURE_SOURCE_HASH:-sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}}"
  CONSOLE_FIXTURE_PHASE_SOURCE_HASH="$phase_hash"
  export CONSOLE_FIXTURE_PHASE_SOURCE_HASH

  phase_status=0
  # Each phase runs in its own deploy-executor.sh *process*, exactly as a real
  # `--action test` and a later `--action switch` are two separate guarded
  # deploys. Two reasons this is not merely cosmetic:
  #
  #   * it keeps the executor's own errexit semantics. Calling the function as
  #     `( deploy_main ) || status=$?` — or `deploy_main || status=$?` — puts
  #     the subshell in a conditional context, which disables errexit *inside*
  #     deploy_main, so a mid-transaction step that fails without re-raising its
  #     status is swallowed and the phase still reports success;
  #   * the second phase is genuinely the next guarded deploy: it re-reads the
  #     stamp, lock and committed boot generation the first one left on the
  #     simulated host, instead of inheriting the first process's shell state.
  #
  # The child re-sources the executor, which reassigns its own defaults, so the
  # test-only overrides are exported and re-applied after that source.
  #
  # `env --default-signal=HUP,INT,TERM` mirrors what deploy-executor.sh does for
  # a direct invocation. Bash cannot install a trap for a signal that was already
  # ignored when the shell started, and a test runner may well start us that way
  # (the lean gate does). Without this the transaction is refused up front with
  # "could not install the INT deploy recovery trap", which would be an artefact
  # of how the test was launched rather than anything about the console route.
  env --default-signal=HUP,INT,TERM bash -c '
    set -Eeuo pipefail
    source scripts/helpers/deploy-executor.sh
    deploy_target_path="$CONSOLE_FIXTURE_TARGET_PATH"
    activation_poll_attempts="$CONSOLE_FIXTURE_POLL_ATTEMPTS"
    activation_poll_interval="$CONSOLE_FIXTURE_POLL_INTERVAL"
    deploy_main
  ' || phase_status=$?

  printf 'PHASE=%s EXECUTOR_STATUS=%s LOCK_PRESENT=%s STAMP_PRESENT=%s\n' \
    "$phase" \
    "$phase_status" \
    "$([[ -d "$deploy_lock_dir" ]] && echo yes || echo no)" \
    "$([[ -f "$test_stamp_path" ]] && echo yes || echo no)"
  printf 'PHASE=%s BOOT_PROFILE=%s\n' "$phase" "$(readlink -f /nix/var/nix/profiles/system)"
  printf 'PHASE=%s CURRENT_SYSTEM=%s\n' "$phase" "$(readlink -f /run/current-system)"

  # `events` is a copy of the test phase's log, kept for the assertions that
  # predate the switch phase. Copy it only after the phase has run, so it holds
  # the log that phase produced. With no test phase there is no such log.
  if [[ "$phase" == "test" ]]; then
    cp "$TEST_EVENT_LOG" "$work_dir/events"
  fi

  [[ -n "$first_phase" ]] || first_phase="$phase"
  last_phase="$phase"
  status="$phase_status"
  final_lock_present="$([[ -d "$deploy_lock_dir" ]] && echo yes || echo no)"
  final_stamp_present="$([[ -f "$test_stamp_path" ]] && echo yes || echo no)"

  if [[ "$phase_status" -ne 0 ]]; then
    break
  fi
done

printf 'FIRST_PHASE=%s LAST_PHASE=%s\n' "$first_phase" "$last_phase"
printf 'EXECUTOR_STATUS=%s\n' "$status"
printf 'LOCK_PRESENT=%s\n' "$final_lock_present"
printf 'STAMP_PRESENT=%s\n' "$final_stamp_present"
exit "$status"
