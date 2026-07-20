#!/usr/bin/env bash

set -euo pipefail

test_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Keep signal recovery coverage deterministic when the surrounding validation
# command was launched through nohup or otherwise inherited ignored signals.
# Bash cannot replace a disposition that was ignored when it started, so enter
# one clean shell before sourcing the deploy executor and installing its traps.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${NIXHOMESERVER_DEPLOY_RUNTIME_TEST_SIGNALS_RESET:-}" != "1" ]]; then
  export NIXHOMESERVER_DEPLOY_RUNTIME_TEST_SIGNALS_RESET=1
  exec env --default-signal=HUP,INT,TERM bash "$test_dir/$(basename "${BASH_SOURCE[0]}")" "$@"
fi

source "$test_dir/test-common.sh"

cd "$TESTS_REPO_ROOT"

export TARGET_HOST="admin@test.invalid"
export BUILD_HOST="admin@test.invalid"
export ACTION="test"
export HOSTNAME_ARG="test-host"
export DEBUG_MODE="false"
export BUILD_LOCALLY="false"

# Sourcing the executor must define the transaction without executing it.
source scripts/helpers/deploy-executor.sh
declare -F deploy_main >/dev/null

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

uninstallable_trap_log="$tmpdir/uninstallable-trap.log"
if env --ignore-signal=HUP bash -c '
  set -euo pipefail
  source scripts/helpers/deploy-executor.sh
  arm_deploy_transaction_traps
' >"$uninstallable_trap_log" 2>&1; then
  echo "❌ The deploy executor accepted an inherited, unreplaceable HUP disposition."
  exit 1
fi
if ! rg -Fq 'could not install the HUP deploy recovery trap' "$uninstallable_trap_log"; then
  echo "❌ An unreplaceable HUP disposition failed without an actionable diagnostic."
  cat "$uninstallable_trap_log"
  exit 1
fi

TEST_NIX_FREE_BYTES=$((600 * 1024 * 1024))
TEST_TMP_FREE_BYTES=$((2 * 1024 * 1024 * 1024))
target_command() {
  if [[ "$1" == *" /nix "* ]]; then
    printf '%s\n' "$TEST_NIX_FREE_BYTES"
  elif [[ "$1" == *" /tmp "* ]]; then
    printf '%s\n' "$TEST_TMP_FREE_BYTES"
  else
    echo "unexpected capacity command: $1" >&2
    return 1
  fi
}
ACTION=switch
check_target_free_space >/dev/null
ACTION='test'
if check_target_free_space >/dev/null 2>&1; then
  echo "❌ A test activation accepted switch-only target headroom."
  exit 1
fi
ACTION='test'

captured_target_command=""
target_command() { captured_target_command="$1"; }
target_nix_env="/nix/store/22222222222222222222222222222222-nix/bin/nix-env"
tested_toplevel="/nix/store/33333333333333333333333333333333-nixos-system-tested"
boot_commit_started=false
deploy_lock_acquired=true
commit_boot_generation "$tested_toplevel"
if [[ "$boot_commit_started" != true ]]; then
  echo "❌ A successful boot commit was marked safe before rollback timer/lock cleanup."
  exit 1
fi
boot_commit_started=false
deploy_lock_acquired=false

deploy_lock_dir="$tmpdir/deploy.lock"
deploy_lock_token="expected-owner"
deploy_lock_acquired=true
mkdir "$deploy_lock_dir"
printf '%s\n' "$deploy_lock_token" >"$deploy_lock_dir/owner"
release_script=""
render_lock_release_script release_script
/bin/sh -c "$release_script"
if [[ -e "$deploy_lock_dir" ]]; then
  echo "❌ The matching deploy owner could not release its lock."
  exit 1
fi

mkdir "$deploy_lock_dir"
printf '%s\n' "newer-owner" >"$deploy_lock_dir/owner"
render_lock_release_script release_script
if /bin/sh -c "$release_script" >/dev/null 2>&1; then
  echo "❌ A stale transaction reported successful release of a newer owner's lock."
  exit 1
fi
if [[ ! -f "$deploy_lock_dir/owner" ]]; then
  echo "❌ A stale transaction could release a newer deploy owner's lock."
  exit 1
fi
rm -rf "$deploy_lock_dir"

commit_race_lock="$tmpdir/commit-race.lock"
deploy_lock_dir="$commit_race_lock"
deploy_lock_token="commit-race-owner"
deploy_lock_acquired=true
mkdir "$deploy_lock_dir"
printf '%s\n' "$deploy_lock_token" >"$deploy_lock_dir/owner"
commit_guard_calls=0
target_command() {
  commit_guard_calls=$((commit_guard_calls + 1))
  if ((commit_guard_calls == 1)); then
    # The outer assertion passed; now simulate the delayed rollback completing
    # before the remote boot mutation evaluates its in-command guard.
    return 0
  fi
  touch "$deploy_lock_dir/recovery-complete"
  encoded_guard="${1#sudo /bin/sh -c }"
  guard_script=""
  eval "guard_script=${encoded_guard}"
  /bin/sh -c "$guard_script"
}
boot_commit_started=false
if commit_boot_generation "$tested_toplevel" >"$tmpdir/commit-race.log" 2>&1; then
  echo "❌ Boot commit ignored a recovery-complete marker created after its outer ownership assertion."
  exit 1
fi
if ((commit_guard_calls != 2)); then
  echo "❌ Boot commit race test did not reach the in-command ownership guard."
  exit 1
fi
boot_commit_started=false
deploy_lock_acquired=false
rm -rf "$deploy_lock_dir"

activation_race_lock="$tmpdir/activation-race.lock"
activation_race_calls="$tmpdir/activation-race.calls"
activation_race_mock_bin="$tmpdir/activation-race-bin"
unsafe_activation_log="$tmpdir/unsafe-activation.log"
deploy_lock_dir="$activation_race_lock"
deploy_lock_token="activation-race-owner"
deploy_lock_acquired=true
mkdir "$deploy_lock_dir" "$activation_race_mock_bin"
printf '%s\n' "$deploy_lock_token" >"$deploy_lock_dir/owner"
cat >"$activation_race_mock_bin/systemd-run" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'unsafe-forward-activation:%s\n' "$*" >>"$TEST_UNSAFE_ACTIVATION_LOG"
exit 0
EOF
make_test_executable "$activation_race_mock_bin/systemd-run"
export TEST_UNSAFE_ACTIVATION_LOG="$unsafe_activation_log"
target_command() {
  printf 'call\n' >>"$activation_race_calls"
  activation_race_call_count="$(wc -l <"$activation_race_calls")"
  if ((activation_race_call_count == 1)); then
    # The outer ownership assertion passes while a long build/copy is still
    # current. Delayed recovery then completes before the start command runs.
    return 0
  fi
  if ((activation_race_call_count == 2)); then
    touch "$deploy_lock_dir/recovery-complete"
    encoded_start="${1#sudo /bin/sh -c }"
    guarded_start=""
    eval "guarded_start=${encoded_start}"
    PATH="$activation_race_mock_bin:$PATH" /bin/sh -c "$guarded_start"
    return
  fi
  echo "unexpected activation race command: $1" >&2
  return 2
}
set +e
(
  set -e
  run_detached_activation "$tested_toplevel" test build-marker-race
)
activation_race_status=$?
set -e
if ((activation_race_status == 0)); then
  echo "❌ Forward activation succeeded after delayed recovery completed during the build."
  exit 1
fi
if [[ "$(wc -l <"$activation_race_calls")" != "2" ]] \
  || [[ -e "$unsafe_activation_log" ]]; then
  echo "❌ Forward activation did not atomically reject the recovery marker before systemd-run."
  [[ ! -e "$unsafe_activation_log" ]] || cat "$unsafe_activation_log"
  exit 1
fi
deploy_lock_acquired=false
rm -rf "$deploy_lock_dir"

deploy_lock_dir="$tmpdir/acquire.lock"
deploy_lock_token="acquire-owner"
deploy_lock_acquired=false
captured_target_command=""
target_command() { captured_target_command="$1"; }
acquire_deploy_lock
if [[ "$deploy_lock_acquired" != "true" || -z "$lock_expiry_unit" ]]; then
  echo "❌ Lock acquisition did not retain its armed expiry identity."
  exit 1
fi
encoded_acquire="${captured_target_command##* /bin/sh -c }"
acquire_script=""
eval "acquire_script=${encoded_acquire}"
expiry_prefix="${acquire_script%%systemd-run*}"
mkdir_prefix="${acquire_script%%mkdir *}"
if [[ "$acquire_script" != *"systemd-run"* || "$acquire_script" != *"mkdir "* ]] \
  || ((${#expiry_prefix} >= ${#mkdir_prefix})); then
  echo "❌ Deploy lock was created before its target-side expiry backstop was armed."
  printf '%s\n' "$acquire_script"
  exit 1
fi
deploy_lock_acquired=false
lock_expiry_unit=""

previous_current="/nix/store/00000000000000000000000000000000-nixos-system-old-live"
previous_boot="/nix/store/11111111111111111111111111111111-nixos-system-old-boot"
target_nix_env="/nix/store/22222222222222222222222222222222-nix/bin/nix-env"
deploy_lock_dir="$tmpdir/delayed-rollback.lock"
deploy_lock_token="transaction-owner"
deploy_lock_acquired=true
target_command() {
  captured_target_command="$1"
}

schedule_rollback "15m"
encoded_rollback="${captured_target_command##* /bin/sh -c }"
schedule_script=""
eval "schedule_script=${encoded_rollback}"
encoded_rollback="${schedule_script##* /bin/sh -c }"
rollback_script=""
eval "rollback_script=${encoded_rollback}"

for required in \
  "$previous_current/bin/switch-to-configuration test" \
  "$target_nix_env --profile /nix/var/nix/profiles/system --set $previous_boot" \
  "$previous_boot/bin/switch-to-configuration boot" \
  "$deploy_lock_dir/owner" \
  "$deploy_lock_token"; do
  if [[ "$rollback_script" != *"$required"* ]]; then
    echo "❌ Delayed rollback omitted required state restoration: $required"
    printf '%s\n' "$rollback_script"
    exit 1
  fi
done

live_position="${rollback_script%%"$previous_current/bin/switch-to-configuration test"*}"
profile_position="${rollback_script%%"$target_nix_env --profile"*}"
boot_position="${rollback_script%%"$previous_boot/bin/switch-to-configuration boot"*}"
if (( ${#live_position} >= ${#profile_position} || ${#profile_position} >= ${#boot_position} )); then
  echo "❌ Delayed rollback does not restore live, profile, and boot state in order."
  exit 1
fi

mkdir "$deploy_lock_dir"
printf '%s\n' 'newer-transaction-owner' >"$deploy_lock_dir/owner"
if ! stale_rollback_output="$(/bin/sh -c "$rollback_script" 2>&1)"; then
  echo "❌ A stale delayed rollback failed instead of safely becoming a no-op."
  printf '%s\n' "$stale_rollback_output"
  exit 1
fi
if [[ "$(<"$deploy_lock_dir/owner")" != "newer-transaction-owner" ]] \
  || [[ "$stale_rollback_output" != *"no longer owns its transaction lock"* ]]; then
  echo "❌ A stale delayed rollback touched a newer transaction or lacked a clear diagnostic."
  printf '%s\n' "$stale_rollback_output"
  exit 1
fi
rm -rf "$deploy_lock_dir"
if ! missing_lock_output="$(/bin/sh -c "$rollback_script" 2>&1)"; then
  echo "❌ A delayed rollback whose completed transaction released its lock did not become a no-op."
  printf '%s\n' "$missing_lock_output"
  exit 1
fi
if [[ "$missing_lock_output" != *"no longer owns its transaction lock"* ]]; then
  echo "❌ A missing-lock delayed rollback lacked a clear stale-timer diagnostic."
  printf '%s\n' "$missing_lock_output"
  exit 1
fi

rollback_fixture="$tmpdir/rollback-fixture"
rollback_runtime_log="$tmpdir/rollback-runtime.log"
mkdir -p "$rollback_fixture/old-live/bin" "$rollback_fixture/old-boot/bin" "$rollback_fixture/nix/bin"
cat >"$rollback_fixture/old-live/bin/switch-to-configuration" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'live:%s\n' "$*" >>"$TEST_ROLLBACK_RUNTIME_LOG"
if [[ "${TEST_ROLLBACK_FAIL_LIVE:-}" == "1" ]]; then
  exit 9
fi
EOF
cat >"$rollback_fixture/old-boot/bin/switch-to-configuration" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'boot:%s\n' "$*" >>"$TEST_ROLLBACK_RUNTIME_LOG"
EOF
cat >"$rollback_fixture/nix/bin/nix-env" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'profile:%s\n' "$*" >>"$TEST_ROLLBACK_RUNTIME_LOG"
EOF
make_test_executable \
  "$rollback_fixture/old-live/bin/switch-to-configuration" \
  "$rollback_fixture/old-boot/bin/switch-to-configuration" \
  "$rollback_fixture/nix/bin/nix-env"
export TEST_ROLLBACK_RUNTIME_LOG="$rollback_runtime_log"
previous_current="$rollback_fixture/old-live"
previous_boot="$rollback_fixture/old-boot"
target_nix_env="$rollback_fixture/nix/bin/nix-env"
deploy_lock_dir="$rollback_fixture/owned.lock"
deploy_lock_token="runtime-owner"
mkdir "$deploy_lock_dir"
printf '%s\n' "$deploy_lock_token" >"$deploy_lock_dir/owner"
schedule_rollback "15m"
encoded_rollback="${captured_target_command##* /bin/sh -c }"
schedule_script=""
eval "schedule_script=${encoded_rollback}"
encoded_rollback="${schedule_script##* /bin/sh -c }"
matching_rollback_script=""
eval "matching_rollback_script=${encoded_rollback}"
if ! /bin/sh -c "$matching_rollback_script"; then
  echo "❌ A delayed rollback with the matching transaction token could not restore state."
  exit 1
fi
expected_profile_event="profile:--profile /nix/var/nix/profiles/system --set $previous_boot"
if [[ "$(cat "$rollback_runtime_log")" != "$(printf 'live:test\n%s\nboot:boot' "$expected_profile_event")" ]] \
  || [[ "$(<"$deploy_lock_dir/owner")" != "$deploy_lock_token" ]] \
  || [[ ! -f "$deploy_lock_dir/recovery-complete" ]] \
  || [[ -e "$deploy_lock_dir/recovery-failed" ]]; then
  echo "❌ An authorised delayed rollback did not restore state and retain an owned completion barrier in order."
  cat "$rollback_runtime_log"
  exit 1
fi

failed_rollback_lock="$rollback_fixture/failed.lock"
deploy_lock_dir="$failed_rollback_lock"
mkdir "$deploy_lock_dir"
printf '%s\n' "$deploy_lock_token" >"$deploy_lock_dir/owner"
export TEST_ROLLBACK_FAIL_LIVE=1
schedule_rollback "15m"
encoded_rollback="${captured_target_command##* /bin/sh -c }"
schedule_script=""
eval "schedule_script=${encoded_rollback}"
encoded_rollback="${schedule_script##* /bin/sh -c }"
failed_rollback_script=""
eval "failed_rollback_script=${encoded_rollback}"
if /bin/sh -c "$failed_rollback_script"; then
  echo "❌ A delayed rollback with a failed restoration step returned success."
  exit 1
fi
unset TEST_ROLLBACK_FAIL_LIVE
if [[ "$(<"$deploy_lock_dir/owner")" != "$deploy_lock_token" ]] \
  || [[ ! -f "$deploy_lock_dir/recovery-failed" ]] \
  || [[ -e "$deploy_lock_dir/recovery-complete" ]]; then
  echo "❌ Failed delayed recovery did not retain an owned blocking marker."
  exit 1
fi
expiry_script=""
render_lock_expiry_script expiry_script
if /bin/sh -c "$expiry_script" >"$tmpdir/failed-expiry.log" 2>&1; then
  echo "❌ Stale-lock expiry cleared a failed delayed-recovery barrier."
  exit 1
fi
if [[ ! -f "$deploy_lock_dir/owner" ]] \
  || ! rg -Fq 'retaining deploy lock after failed delayed recovery' "$tmpdir/failed-expiry.log"; then
  echo "❌ Failed recovery barrier was not retained with an actionable diagnostic."
  cat "$tmpdir/failed-expiry.log"
  exit 1
fi

deploy_lock_dir="$rollback_fixture/owned.lock"

activation_lock="$rollback_fixture/activation.lock"
mkdir "$activation_lock"
printf '%s\n' "$deploy_lock_token" >"$activation_lock/owner"
deploy_lock_dir="$activation_lock"
activation_events="$tmpdir/activation-events.log"
activation_poll_attempts=1
activation_poll_interval=0
target_command() {
  if [[ "$1" == *"sudo systemctl stop"* ]]; then
    printf 'quiesce\n' >>"$activation_events"
    return 0
  fi
  if [[ "$1" == *"systemctl show -P ActiveState"* ]]; then
    printf 'active\n'
    return 0
  fi
  if [[ "$1" == *"systemd-run"* ]]; then
    printf 'start\n' >>"$activation_events"
  fi
  return 0
}
if run_detached_activation \
  "/nix/store/33333333333333333333333333333333-nixos-system-tested" \
  test timeout-probe >"$tmpdir/activation-timeout.log" 2>&1; then
  echo "❌ A detached activation that remained active past its deadline returned success."
  exit 1
fi
if [[ "$active_activation_unit" != "" ]] \
  || [[ "$(cat "$activation_events")" != $'start\nquiesce' ]]; then
  echo "❌ Timed-out activation was not stopped and proven inactive before recovery."
  cat "$activation_events"
  cat "$tmpdir/activation-timeout.log"
  exit 1
fi
activation_poll_attempts=300
activation_poll_interval=2
deploy_lock_dir="$rollback_fixture/owned.lock"

cancel_mock_bin="$tmpdir/cancel-mock-bin"
cancel_mock_log="$tmpdir/cancel-mock.log"
mkdir "$cancel_mock_bin"
cat >"$cancel_mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exec "$@"
EOF
cat >"$cancel_mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_ROLLBACK_CANCEL_LOG"
case "${1:-}" in
  stop|reset-failed)
    exit 0
    ;;
  show)
    unit="${*: -1}"
    if [[ "${TEST_ROLLBACK_SHOW_FAILURE_UNIT:-}" == "$unit" ]]; then
      exit 9
    elif [[ "${TEST_ROLLBACK_ACTIVE_UNIT:-}" == "$unit" ]]; then
      printf 'active\n'
    else
      printf 'inactive\n'
    fi
    ;;
  *)
    echo "unexpected mocked systemctl invocation: $*" >&2
    exit 2
    ;;
esac
EOF
make_test_executable "$cancel_mock_bin/sudo" "$cancel_mock_bin/systemctl"
export TEST_ROLLBACK_CANCEL_LOG="$cancel_mock_log"
target_command() {
  PATH="$cancel_mock_bin:$PATH" bash -c "$1"
}

if deploy_lock_owned >/dev/null 2>&1; then
  echo "❌ A stale executor retained forward-mutation ownership after delayed recovery completed."
  exit 1
fi
if ! deploy_lock_token_owned; then
  echo "❌ Completed delayed recovery did not retain its token for a final safe recovery/cleanup pass."
  exit 1
fi
rollback_unit="rollback-after-delayed-recovery"
if cancel_scheduled_rollback >"$tmpdir/normal-cancel-after-recovery.log" 2>&1; then
  echo "❌ Normal completion accepted a rollback timer that had already restored old state."
  exit 1
fi
if [[ "$rollback_unit" != "rollback-after-delayed-recovery" ]]; then
  echo "❌ Rejected normal completion discarded the delayed-recovery timer identity."
  exit 1
fi

rollback_unit="rollback-cancel-success"
cancel_scheduled_rollback true
if [[ -n "$rollback_unit" ]] \
  || ! rg -Fxq 'stop rollback-cancel-success.timer' "$cancel_mock_log" \
  || rg -Fq 'stop rollback-cancel-success.service' "$cancel_mock_log"; then
  echo "❌ Verified rollback cancellation did not clear only an inactive timer."
  cat "$cancel_mock_log"
  exit 1
fi

: >"$cancel_mock_log"
rollback_unit="rollback-cancel-active"
export TEST_ROLLBACK_ACTIVE_UNIT="${rollback_unit}.timer"
if cancel_scheduled_rollback true >"$tmpdir/cancel-active.log" 2>&1; then
  echo "❌ Rollback cancellation accepted a timer that remained active."
  exit 1
fi
unset TEST_ROLLBACK_ACTIVE_UNIT
if [[ "$rollback_unit" != "rollback-cancel-active" ]] \
  || ! rg -Fq 'remained in unsafe state: active' "$tmpdir/cancel-active.log"; then
  echo "❌ Failed rollback cancellation discarded the armed timer identity or its diagnostic."
  cat "$tmpdir/cancel-active.log"
  exit 1
fi

: >"$cancel_mock_log"
rollback_unit="rollback-cancel-query-failure"
export TEST_ROLLBACK_SHOW_FAILURE_UNIT="${rollback_unit}.timer"
if cancel_scheduled_rollback true >"$tmpdir/cancel-query-failure.log" 2>&1; then
  echo "❌ Rollback cancellation treated an unverifiable timer state as inactive."
  exit 1
fi
unset TEST_ROLLBACK_SHOW_FAILURE_UNIT
if [[ "$rollback_unit" != "rollback-cancel-query-failure" ]]; then
  echo "❌ An unverifiable cancellation discarded the armed timer identity."
  exit 1
fi

events="$tmpdir/immediate-events"
set +e
(
  set -e
  activation_started=true
  boot_commit_started=true
  rollback_unit="rollback-unit"
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  rollback_live_generation() { printf 'live\n' >>"$events"; }
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  restore_boot_generation() { printf 'boot\n' >>"$events"; }
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  cancel_scheduled_rollback() { printf 'cancel\n' >>"$events"; }
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  release_deploy_lock() { printf 'unlock\n' >>"$events"; }
  arm_deploy_transaction_traps
  false
)
transaction_status=$?
set -e
if ((transaction_status != 1)); then
  echo "❌ A failed deployment transaction returned ${transaction_status}, expected 1."
  exit 1
fi
if [[ "$(cat "$events")" != $'live\nboot\ncancel\nunlock' ]]; then
  echo "❌ Immediate failure recovery did not restore both generations before cleanup."
  cat "$events"
  exit 1
fi

: >"$events"
set +e
(
  set -e
  activation_started=true
  boot_commit_started=false
  rollback_unit="rollback-unit"
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  rollback_live_generation() { printf 'live\n' >>"$events"; }
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  cancel_scheduled_rollback() { printf 'cancel-failed\n' >>"$events"; return 1; }
  # shellcheck disable=SC2329 # Must remain uncalled while cancellation is uncertain.
  release_deploy_lock() { printf 'unsafe-unlock\n' >>"$events"; }
  arm_deploy_transaction_traps
  false
)
transaction_status=$?
set -e
if ((transaction_status != 1)); then
  echo "❌ Cancellation-uncertain recovery returned ${transaction_status}, expected 1."
  exit 1
fi
if [[ "$(cat "$events")" != $'live\ncancel-failed' ]]; then
  echo "❌ Unverified rollback cancellation released or invalidated its transaction lock."
  cat "$events"
  exit 1
fi

: >"$events"
set +e
(
  set -e
  activation_started=true
  boot_commit_started=true
  rollback_unit="rollback-unit"
  active_activation_unit="still-running"
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  quiesce_active_activation() { printf 'quiesce-failed\n' >>"$events"; return 1; }
  # shellcheck disable=SC2329 # Must remain uncalled without quiescence proof.
  rollback_live_generation() { printf 'unsafe-live-rollback\n' >>"$events"; }
  # shellcheck disable=SC2329 # Must remain uncalled without quiescence proof.
  restore_boot_generation() { printf 'unsafe-boot-rollback\n' >>"$events"; }
  # shellcheck disable=SC2329 # Must remain uncalled without quiescence proof.
  cancel_scheduled_rollback() { printf 'unsafe-cancel\n' >>"$events"; }
  # shellcheck disable=SC2329 # Must remain uncalled without quiescence proof.
  release_deploy_lock() { printf 'unsafe-unlock\n' >>"$events"; }
  arm_deploy_transaction_traps
  false
)
transaction_status=$?
set -e
if ((transaction_status != 1)) || [[ "$(cat "$events")" != "quiesce-failed" ]]; then
  echo "❌ Recovery mutated state without proving the detached activation was inactive."
  cat "$events"
  exit 1
fi

: >"$events"
set +e
(
  set -e
  activation_started=true
  boot_commit_started=false
  rollback_unit="rollback-unit"
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  rollback_live_generation() { printf 'live-failed\n' >>"$events"; return 1; }
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  cancel_scheduled_rollback() { printf 'cancel\n' >>"$events"; }
  # shellcheck disable=SC2329 # Invoked indirectly by handle_transaction_failure.
  release_deploy_lock() { printf 'unlock\n' >>"$events"; }
  arm_deploy_transaction_traps
  false
)
transaction_status=$?
set -e
if ((transaction_status == 0)); then
  echo "❌ A transaction with failed immediate rollback returned success."
  exit 1
fi
if [[ "$(cat "$events")" != "live-failed" ]]; then
  echo "❌ Failed immediate rollback disarmed its delayed recovery or lock."
  cat "$events"
  exit 1
fi

for signal_case in HUP:129 INT:130 TERM:143; do
  IFS=: read -r signal_name expected_status <<<"$signal_case"
  : >"$events"
  set +e
  (
    set -e
    activation_started=true
    boot_commit_started=true
    rollback_unit="rollback-unit"
    # shellcheck disable=SC2329 # Invoked indirectly by the transaction trap.
    rollback_live_generation() { printf 'live\n' >>"$events"; }
    # shellcheck disable=SC2329 # Invoked indirectly by the transaction trap.
    restore_boot_generation() { printf 'boot\n' >>"$events"; }
    # shellcheck disable=SC2329 # Invoked indirectly by the transaction trap.
    cancel_scheduled_rollback() { printf 'cancel\n' >>"$events"; }
    # shellcheck disable=SC2329 # Invoked indirectly by the transaction trap.
    release_deploy_lock() { printf 'unlock\n' >>"$events"; }
    arm_deploy_transaction_traps
    kill -s "$signal_name" "$BASHPID"
    printf 'continued-after-signal\n' >>"$events"
  ) 2>"$tmpdir/signal-${signal_name}.log"
  transaction_status=$?
  set -e

  if ((transaction_status != expected_status)); then
    echo "❌ ${signal_name} recovery returned ${transaction_status}, expected ${expected_status}."
    cat "$tmpdir/signal-${signal_name}.log"
    exit 1
  fi
  if [[ "$(cat "$events")" != $'live\nboot\ncancel\nunlock' ]]; then
    echo "❌ ${signal_name} did not restore both generations before cleanup."
    cat "$events"
    exit 1
  fi
  if ! rg -Fq "deployment interrupted by ${signal_name}" "$tmpdir/signal-${signal_name}.log"; then
    echo "❌ ${signal_name} recovery lacked an actionable interruption diagnostic."
    cat "$tmpdir/signal-${signal_name}.log"
    exit 1
  fi
done

echo "✅ Deploy transaction runtime tests passed."
