#!/usr/bin/env bash

set -euo pipefail

helper_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Bash cannot replace a signal disposition that was already ignored when the
# shell started.  Re-exec direct invocations once with known dispositions so
# HUP/INT/TERM always reach the guarded transaction handlers, even when a
# caller started deploy.sh through nohup or another signal-modifying wrapper.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${NIXHOMESERVER_DEPLOY_SIGNALS_RESET:-}" != "1" ]]; then
  export NIXHOMESERVER_DEPLOY_SIGNALS_RESET=1
  exec env --default-signal=HUP,INT,TERM bash "$helper_dir/deploy-executor.sh" "$@"
fi

source "$helper_dir/deploy-command.sh"
source "$helper_dir/deploy-transaction.sh"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes
accept-flake-config = true}"

: "${TARGET_HOST:?missing TARGET_HOST}"
: "${BUILD_HOST:?missing BUILD_HOST}"
: "${ACTION:?missing ACTION}"
: "${HOSTNAME_ARG:?missing HOSTNAME_ARG}"
: "${DEBUG_MODE:=false}"
: "${BUILD_LOCALLY:=false}"

min_build_host_free_bytes=$((10 * 1024 * 1024 * 1024))
min_target_nix_free_bytes=$((5 * 1024 * 1024 * 1024))
min_switch_target_nix_free_bytes=$((512 * 1024 * 1024))
min_tmp_free_bytes=$((1 * 1024 * 1024 * 1024))
deploy_state_dir="/var/lib/nixhomeserver-deploy"
test_stamp_path="${deploy_state_dir}/last-tested-${HOSTNAME_ARG}.stamp"
test_gcroot_dir="/nix/var/nix/gcroots/nixhomeserver-tested"
test_gcroot_path="${test_gcroot_dir}/${HOSTNAME_ARG}"
deploy_lock_dir="/run/lock/nixhomeserver-deploy-${HOSTNAME_ARG}"
deploy_lock_token="$(date +%s%N)-$$"

source_hash=""
previous_current=""
previous_boot=""
target_nix_env=""
activated_toplevel=""
rollback_unit=""
lock_expiry_unit=""
deploy_lock_acquired=false
activation_started=false
boot_commit_started=false
transaction_complete=false
active_activation_unit=""
activation_poll_attempts=300
activation_poll_interval=2

human_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
}

target_is_local() {
  [[ "$BUILD_LOCALLY" != "true" && "$TARGET_HOST" == "$BUILD_HOST" ]]
}

target_command() {
  local command="$1"

  if target_is_local; then
    bash -c "$command"
  else
    ssh "$TARGET_HOST" "$command"
  fi
}

check_free_space() {
  local sandbox_build_dir build_backing_path build_available_bytes tmp_available_bytes

  sandbox_build_dir="$(nix config show 2>/dev/null | sed -n 's/^sandbox-build-dir = //p' | head -n 1)"
  if [[ -z "$sandbox_build_dir" ]]; then
    sandbox_build_dir="/build"
  fi

  build_backing_path="$sandbox_build_dir"
  while [[ ! -e "$build_backing_path" && "$build_backing_path" != "/" ]]; do
    build_backing_path="$(dirname "$build_backing_path")"
  done

  build_available_bytes="$(df -B1 --output=avail "$build_backing_path" | awk 'NR==2 { print $1 }')"
  tmp_available_bytes="$(df -B1 --output=avail /tmp | awk 'NR==2 { print $1 }')"

  echo "build space: ${build_backing_path} $(human_bytes "$build_available_bytes"), /tmp $(human_bytes "$tmp_available_bytes")"

  if ((build_available_bytes < min_build_host_free_bytes)); then
    echo "blocked: build host has insufficient Nix build space" >&2
    return 1
  fi

  if ((tmp_available_bytes < min_tmp_free_bytes)); then
    echo "blocked: build host has insufficient /tmp space" >&2
    return 1
  fi
}

check_target_free_space() {
  local target_nix_available target_tmp_available required_nix_free_bytes

  if [[ "$ACTION" == "switch" ]]; then
    required_nix_free_bytes="$min_switch_target_nix_free_bytes"
  else
    required_nix_free_bytes="$min_target_nix_free_bytes"
  fi

  target_nix_available="$(target_command "df -B1 --output=avail /nix | awk 'NR==2 { print \$1 }'")"
  target_tmp_available="$(target_command "df -B1 --output=avail /tmp | awk 'NR==2 { print \$1 }'")"
  [[ "$target_nix_available" =~ ^[0-9]+$ && "$target_tmp_available" =~ ^[0-9]+$ ]] || {
    echo "blocked: target free-space query returned invalid data" >&2
    return 1
  }

  echo "target space: /nix $(human_bytes "$target_nix_available"), /tmp $(human_bytes "$target_tmp_available")"
  if ((target_nix_available < required_nix_free_bytes)); then
    echo "blocked: target host has insufficient /nix space for ${ACTION} activation" >&2
    return 1
  fi
  if ((target_tmp_available < min_tmp_free_bytes)); then
    echo "blocked: target host has insufficient /tmp space" >&2
    return 1
  fi
}

check_failed_units() {
  local failed_units failed_unit failed_unit_quoted

  if target_is_local; then
    sudo systemctl --failed --no-pager
    failed_units="$(sudo systemctl --failed --no-legend --plain | awk '{ print $1 }' || true)"
  else
    ssh "$TARGET_HOST" "sudo systemctl --failed --no-pager"
    failed_units="$(ssh "$TARGET_HOST" "sudo systemctl --failed --no-legend --plain | awk '{ print \$1 }'" || true)"
  fi

  if [[ -n "$failed_units" ]]; then
    if [[ "$DEBUG_MODE" == "true" ]]; then
      if target_is_local; then
        while IFS= read -r failed_unit; do
          [[ -n "$failed_unit" ]] || continue
          sudo systemctl status --no-pager "$failed_unit" || true
        done <<<"$failed_units"
        sudo journalctl -p warning..alert -n 200 --no-pager || true
      else
        while IFS= read -r failed_unit; do
          [[ -n "$failed_unit" ]] || continue
          failed_unit_quoted="$(printf '%q' "$failed_unit")"
          ssh -n "$TARGET_HOST" "sudo systemctl status --no-pager $failed_unit_quoted || true"
        done <<<"$failed_units"
        ssh "$TARGET_HOST" "sudo journalctl -p warning..alert -n 200 --no-pager || true"
      fi
    fi
    echo "blocked: failed systemd units detected" >&2
    return 1
  fi
}

target_readlink() {
  local path="$1"
  target_command "readlink -f $(printf '%q' "$path")"
}

capture_previous_state() {
  previous_current="$(target_readlink /run/current-system)"
  previous_boot="$(target_readlink /nix/var/nix/profiles/system)"
  target_nix_env="$(target_command "readlink -f \"\$(command -v nix-env)\"")"
  deploy_validate_toplevel_path "$previous_current" || {
    echo "blocked: current target generation is not a valid Nix store path" >&2
    return 1
  }
  deploy_validate_toplevel_path "$previous_boot" || {
    echo "blocked: target boot profile is not a valid Nix store path" >&2
    return 1
  }
  if [[ ! "$target_nix_env" =~ ^/nix/store/[a-z0-9]{32}-[^[:space:]]+/bin/nix-env$ ]] \
    || ! target_command "test -x $(printf '%q' "$target_nix_env")"; then
    echo "blocked: target nix-env executable could not be resolved safely" >&2
    return 1
  fi
}

deploy_recovery_marker_path() {
  printf '%s/recovery-failed' "$deploy_lock_dir"
}

deploy_recovery_complete_marker_path() {
  printf '%s/recovery-complete' "$deploy_lock_dir"
}

render_lock_release_script() {
  local -n output_script="$1"
  local owner_path="${deploy_lock_dir}/owner"
  local recovery_complete_marker recovery_marker

  recovery_marker="$(deploy_recovery_marker_path)"
  recovery_complete_marker="$(deploy_recovery_complete_marker_path)"

  # shellcheck disable=SC2034 # Assigned through the caller-provided nameref.
  output_script="if test -f $(printf '%q' "$owner_path") && test \"\$(cat $(printf '%q' "$owner_path"))\" = $(printf '%q' "$deploy_lock_token"); then rm -f $(printf '%q' "$recovery_marker") $(printf '%q' "$recovery_complete_marker") $(printf '%q' "$owner_path") && rmdir $(printf '%q' "$deploy_lock_dir"); else echo 'blocked: deploy transaction no longer owns its lock' >&2; exit 1; fi"
}

render_lock_expiry_script() {
  local -n output_script="$1"
  local owner_path="${deploy_lock_dir}/owner"
  local recovery_complete_marker recovery_marker

  recovery_marker="$(deploy_recovery_marker_path)"
  recovery_complete_marker="$(deploy_recovery_complete_marker_path)"

  # A failed delayed rollback is a durable blocking state. It must be inspected
  # or superseded by a later, successful recovery rather than silently unlocked
  # by the ordinary stale-lock timer.
  # shellcheck disable=SC2034 # Assigned through the caller-provided nameref.
  output_script="if test -e $(printf '%q' "$recovery_marker"); then echo 'blocked: retaining deploy lock after failed delayed recovery' >&2; exit 1; elif test -f $(printf '%q' "$owner_path") && test \"\$(cat $(printf '%q' "$owner_path"))\" = $(printf '%q' "$deploy_lock_token"); then rm -f $(printf '%q' "$recovery_complete_marker") $(printf '%q' "$owner_path") && rmdir $(printf '%q' "$deploy_lock_dir"); elif ! test -e $(printf '%q' "$owner_path"); then rmdir $(printf '%q' "$deploy_lock_dir") 2>/dev/null || true; fi"
}

deploy_lock_token_owned() {
  local owner_path="${deploy_lock_dir}/owner"
  local ownership_script

  [[ "$deploy_lock_acquired" == "true" ]] || return 1
  ownership_script="test -f $(printf '%q' "$owner_path") && test \"\$(cat $(printf '%q' "$owner_path"))\" = $(printf '%q' "$deploy_lock_token")"
  target_command "sudo /bin/sh -c $(printf '%q' "$ownership_script")"
}

deploy_lock_owned() {
  local owner_path="${deploy_lock_dir}/owner"
  local ownership_script recovery_complete_marker recovery_marker

  recovery_marker="$(deploy_recovery_marker_path)"
  recovery_complete_marker="$(deploy_recovery_complete_marker_path)"
  [[ "$deploy_lock_acquired" == "true" ]] || return 1
  ownership_script="test -f $(printf '%q' "$owner_path") && test \"\$(cat $(printf '%q' "$owner_path"))\" = $(printf '%q' "$deploy_lock_token") && ! test -e $(printf '%q' "$recovery_marker") && ! test -e $(printf '%q' "$recovery_complete_marker")"
  target_command "sudo /bin/sh -c $(printf '%q' "$ownership_script")"
}

assert_deploy_lock_token_owned() {
  if ! deploy_lock_token_owned; then
    echo "blocked: deployment transaction no longer owns token for ${deploy_lock_dir}" >&2
    return 1
  fi
}

assert_deploy_lock_owned() {
  if ! deploy_lock_owned; then
    echo "blocked: deployment transaction lost ownership of ${deploy_lock_dir}" >&2
    return 1
  fi
}

acquire_deploy_lock() {
  local acquire_script expiry_script owner_path timer_service timer_timer

  owner_path="${deploy_lock_dir}/owner"
  lock_expiry_unit="nixhomeserver-deploy-unlock-${HOSTNAME_ARG}-$(date +%s%N)-$$"
  timer_timer="${lock_expiry_unit}.timer"
  timer_service="${lock_expiry_unit}.service"
  render_lock_expiry_script expiry_script

  # Arm cleanup before creating the lock. If the remote shell or SSH transport
  # disappears at any later point, an acquired lock always has a target-side
  # expiry backstop. A failed mkdir cancels only this transaction's unique timer.
  acquire_script="set -e; umask 077; systemd-run --quiet --unit=$(printf '%q' "$lock_expiry_unit") --on-active=26h --description='NixHomeServer stale deploy lock cleanup' /bin/sh -c $(printf '%q' "$expiry_script"); if mkdir $(printf '%q' "$deploy_lock_dir"); then if printf '%s\\n' $(printf '%q' "$deploy_lock_token") > $(printf '%q' "$owner_path"); then exit 0; fi; rmdir $(printf '%q' "$deploy_lock_dir") 2>/dev/null || true; fi; systemctl stop $(printf '%q' "$timer_timer") $(printf '%q' "$timer_service") >/dev/null 2>&1 || true; systemctl reset-failed $(printf '%q' "$timer_service") >/dev/null 2>&1 || true; exit 1"
  if ! target_command "sudo /bin/sh -c $(printf '%q' "$acquire_script")"; then
    echo "blocked: could not acquire ${deploy_lock_dir} with an armed expiry timer; another deployment may already hold it" >&2
    lock_expiry_unit=""
    return 1
  fi
  deploy_lock_acquired=true
}

release_deploy_lock() {
  local release_script

  [[ "$deploy_lock_acquired" == "true" ]] || return 0
  [[ -z "$rollback_unit" ]] || {
    echo "blocked: refusing to release deploy lock while rollback unit ${rollback_unit} is not conclusively cancelled" >&2
    return 1
  }
  assert_deploy_lock_token_owned
  render_lock_release_script release_script
  target_command "sudo /bin/sh -c $(printf '%q' "$release_script")"
  if [[ -n "$lock_expiry_unit" ]]; then
    target_command "sudo systemctl stop $(printf '%q' "$lock_expiry_unit.timer") $(printf '%q' "$lock_expiry_unit.service") >/dev/null 2>&1 || true; sudo systemctl reset-failed $(printf '%q' "$lock_expiry_unit.service") >/dev/null 2>&1 || true"
  fi
  deploy_lock_acquired=false
  lock_expiry_unit=""
}

quiesce_active_activation() {
  local unit="${active_activation_unit:-}"
  local quiesce_script

  [[ -n "$unit" ]] || return 0
  quiesce_script="sudo systemctl stop $(printf '%q' "$unit") >/dev/null 2>&1 || true; load_state=\$(sudo systemctl show -P LoadState $(printf '%q' "$unit") 2>/dev/null || true); active_state=\$(sudo systemctl show -P ActiveState $(printf '%q' "$unit") 2>/dev/null || true); case \"\$load_state:\$active_state\" in loaded:inactive|loaded:failed|not-found:inactive) ;; *) echo \"blocked: activation unit $(printf '%q' "$unit") remained in unsafe state: load=\$load_state active=\$active_state\" >&2; exit 1 ;; esac"
  if ! target_command "$quiesce_script"; then
    echo "blocked: could not prove activation ${unit} was inactive before recovery" >&2
    return 1
  fi
  active_activation_unit=""
}

run_detached_activation() {
  local toplevel="$1"
  local mode="$2"
  local label="$3"
  local marker_guard recovery_complete_marker unit state="" result status start_command recovery_marker

  deploy_validate_toplevel_path "$toplevel" || return 1
  [[ "$mode" == "test" || "$mode" == "boot" ]] || return 1
  unit="nixos-detached-${label}-$(date +%s%N)-$$"
  recovery_complete_marker="$(deploy_recovery_complete_marker_path)"
  recovery_marker="$(deploy_recovery_marker_path)"
  if [[ "$label" == "rollback" ]]; then
    assert_deploy_lock_token_owned
    marker_guard=":"
  else
    assert_deploy_lock_owned
    marker_guard="test ! -e ${recovery_marker} && test ! -e ${recovery_complete_marker}"
  fi
  start_command="sudo /bin/sh -c $(printf '%q' "test -f ${deploy_lock_dir}/owner && test \"\$(cat ${deploy_lock_dir}/owner)\" = ${deploy_lock_token} && ${marker_guard} && exec systemd-run --unit=$(printf '%q' "$unit") --description='Detached NixOS ${label} activation' --service-type=exec $(printf '%q' "$toplevel/bin/switch-to-configuration") $(printf '%q' "$mode")")"

  echo "starting detached ${label} activation as ${unit}"
  active_activation_unit="$unit"
  target_command "$start_command"

  for ((attempt = 1; attempt <= activation_poll_attempts; attempt++)); do
    state="$(target_command "systemctl show -P ActiveState $(printf '%q' "$unit") 2>/dev/null")"
    case "$state" in
      active|activating|reloading|deactivating)
        sleep "$activation_poll_interval"
        ;;
      inactive|failed)
        break
        ;;
      *)
        echo "blocked: detached ${label} activation returned unknown state '${state}'" >&2
        quiesce_active_activation || true
        return 1
        ;;
    esac
  done

  if [[ "$state" == "active" || "$state" == "activating" || "$state" == "reloading" || "$state" == "deactivating" ]]; then
    echo "blocked: detached ${label} activation timed out" >&2
    quiesce_active_activation || true
    return 1
  fi

  result="$(target_command "systemctl show -P Result $(printf '%q' "$unit") 2>/dev/null || true")"
  status="$(target_command "systemctl show -P ExecMainStatus $(printf '%q' "$unit") 2>/dev/null || true")"

  if [[ "$result" != "success" || "$status" != "0" ]]; then
    target_command "sudo systemctl status --no-pager $(printf '%q' "$unit") || true"
    echo "blocked: detached ${label} activation failed" >&2
    active_activation_unit=""
    return 1
  fi

  target_command "sudo systemctl reset-failed $(printf '%q' "$unit") >/dev/null 2>&1 || true"
  active_activation_unit=""
}

schedule_rollback() {
  local delay="$1"
  local complete_marker_quoted failure_marker_quoted owner_path recovery_complete_marker recovery_marker rollback_script scheduled_unit

  assert_deploy_lock_owned
  owner_path="${deploy_lock_dir}/owner"
  recovery_marker="$(deploy_recovery_marker_path)"
  recovery_complete_marker="$(deploy_recovery_complete_marker_path)"
  failure_marker_quoted="$(printf '%q' "$recovery_marker")"
  complete_marker_quoted="$(printf '%q' "$recovery_complete_marker")"
  rollback_script="if test -f $(printf '%q' "$owner_path") && test \"\$(cat $(printf '%q' "$owner_path"))\" = $(printf '%q' "$deploy_lock_token") && ! test -e ${failure_marker_quoted}; then status=0; $(printf '%q' "$previous_current/bin/switch-to-configuration") test || status=1; $(printf '%q' "$target_nix_env") --profile /nix/var/nix/profiles/system --set $(printf '%q' "$previous_boot") || status=1; $(printf '%q' "$previous_boot/bin/switch-to-configuration") boot || status=1; if test -f $(printf '%q' "$owner_path") && test \"\$(cat $(printf '%q' "$owner_path"))\" = $(printf '%q' "$deploy_lock_token"); then umask 077; if test \"\$status\" -eq 0; then rm -f ${failure_marker_quoted}; printf '%s\\n' 'delayed rollback completed; stale executor remains blocked until it exits or the lock expires' > ${complete_marker_quoted}; else rm -f ${complete_marker_quoted}; printf '%s\\n' 'delayed rollback failed; inspect the rollback service before clearing this lock' > ${failure_marker_quoted}; fi; fi; exit \$status; else echo 'stale deploy rollback no longer owns its transaction lock; skipping generation changes' >&2; exit 0; fi"
  scheduled_unit="nixhomeserver-deploy-rollback-${HOSTNAME_ARG}-$(date +%s%N)-$$"
  target_command "sudo /bin/sh -c $(printf '%q' "test -f ${owner_path} && test \"\$(cat ${owner_path})\" = ${deploy_lock_token} && ! test -e ${recovery_marker} && ! test -e ${recovery_complete_marker} && exec systemd-run --quiet --unit=$(printf '%q' "$scheduled_unit") --on-active=$(printf '%q' "$delay") --description='NixHomeServer interrupted deploy rollback' /bin/sh -c $(printf '%q' "$rollback_script")")"
  rollback_unit="$scheduled_unit"
  echo "scheduled target-side rollback ${rollback_unit}.timer after ${delay}"
}

cancel_scheduled_rollback() {
  local cancel_script marker_guard recovery_mode="${1:-false}" rollback_service rollback_timer

  [[ -n "$rollback_unit" ]] || return 0
  if [[ "$recovery_mode" == "true" ]]; then
    assert_deploy_lock_token_owned
  else
    assert_deploy_lock_owned
  fi
  rollback_timer="${rollback_unit}.timer"
  rollback_service="${rollback_unit}.service"
  if [[ "$recovery_mode" == "true" ]]; then
    marker_guard=":"
  else
    marker_guard="test ! -e $(deploy_recovery_marker_path) && test ! -e $(deploy_recovery_complete_marker_path)"
  fi
  cancel_script="set -e; test -f $(printf '%q' "$deploy_lock_dir/owner"); test \"\$(cat $(printf '%q' "$deploy_lock_dir/owner"))\" = $(printf '%q' "$deploy_lock_token"); ${marker_guard}; sudo systemctl stop $(printf '%q' "$rollback_timer") >/dev/null 2>&1 || true; for unit in $(printf '%q' "$rollback_timer") $(printf '%q' "$rollback_service"); do state=\$(sudo systemctl show -P ActiveState \"\$unit\"); case \"\$state\" in inactive|failed) ;; *) echo \"blocked: rollback unit \$unit remained in unsafe state: \$state\" >&2; exit 1 ;; esac; done; ${marker_guard}; sudo systemctl reset-failed $(printf '%q' "$rollback_service") >/dev/null 2>&1 || true"
  target_command "$cancel_script" || return
  rollback_unit=""
}

rollback_live_generation() {
  [[ -n "$previous_current" ]] || return 1
  quiesce_active_activation
  assert_deploy_lock_token_owned
  echo "rolling live target back to ${previous_current}" >&2
  run_detached_activation "$previous_current" test rollback
}

restore_boot_generation() {
  [[ -n "$previous_boot" ]] || return 1
  assert_deploy_lock_token_owned
  echo "restoring boot profile ${previous_boot}" >&2
  target_command "sudo /bin/sh -c $(printf '%q' "test -f ${deploy_lock_dir}/owner && test \"\$(cat ${deploy_lock_dir}/owner)\" = ${deploy_lock_token} && $(printf '%q' "$target_nix_env") --profile /nix/var/nix/profiles/system --set $(printf '%q' "$previous_boot") && $(printf '%q' "$previous_boot/bin/switch-to-configuration") boot")"
}

handle_transaction_failure() {
  local status="$1"
  local quiescence_ok=true
  local rollback_ok=true

  # Recovery must not itself be interrupted by a second terminal signal. The
  # process exits with the original error/signal status once cleanup finishes.
  trap - ERR
  trap '' HUP INT TERM
  set +e
  quiesce_active_activation || {
    quiescence_ok=false
    rollback_ok=false
  }
  if [[ "$quiescence_ok" == "true" && "$activation_started" == "true" ]]; then
    rollback_live_generation || rollback_ok=false
  fi
  if [[ "$quiescence_ok" == "true" && "$boot_commit_started" == "true" ]]; then
    restore_boot_generation || rollback_ok=false
  fi
  if [[ "$rollback_ok" == "true" ]]; then
    if cancel_scheduled_rollback true; then
      release_deploy_lock || true
    else
      echo "warning: rollback cancellation could not be verified; leaving the timer and deploy lock armed" >&2
    fi
  elif [[ -n "$rollback_unit" ]]; then
    echo "warning: immediate rollback failed; leaving ${rollback_unit}.timer armed" >&2
  else
    echo "warning: immediate recovery failed without a rollback timer; retaining the deploy lock for inspection" >&2
  fi
  exit "$status"
}

handle_transaction_signal() {
  local signal_name="$1"
  local signal_status="$2"

  echo "warning: deployment interrupted by ${signal_name}; starting immediate transaction recovery" >&2
  handle_transaction_failure "$signal_status"
}

arm_deploy_transaction_traps() {
  local signal_name signal_status trap_definition

  trap 'handle_transaction_signal HUP 129' HUP
  trap 'handle_transaction_signal INT 130' INT
  trap 'handle_transaction_signal TERM 143' TERM

  for signal_name in HUP INT TERM; do
    case "$signal_name" in
      HUP) signal_status=129 ;;
      INT) signal_status=130 ;;
      TERM) signal_status=143 ;;
    esac
    trap_definition="$(trap -p "$signal_name")"
    if [[ "$trap_definition" != *"handle_transaction_signal ${signal_name} ${signal_status}"* ]]; then
      echo "blocked: could not install the ${signal_name} deploy recovery trap; refusing to start a transaction" >&2
      return 1
    fi
  done

  trap 'handle_transaction_failure "$?"' ERR
}

clear_deploy_transaction_traps() {
  trap - ERR HUP INT TERM
}

write_test_stamp() {
  local toplevel="$1"
  local gcroot_dir_quoted gcroot_path_quoted recovery_marker source_hash_quoted stamp_path_quoted toplevel_quoted write_script

  assert_deploy_lock_owned
  recovery_marker="$(deploy_recovery_marker_path)"
  deploy_render_test_stamp "$source_hash" "$toplevel" >/dev/null
  source_hash_quoted="$(printf '%q' "$source_hash")"
  stamp_path_quoted="$(printf '%q' "$test_stamp_path")"
  gcroot_dir_quoted="$(printf '%q' "$test_gcroot_dir")"
  gcroot_path_quoted="$(printf '%q' "$test_gcroot_path")"
  toplevel_quoted="$(printf '%q' "$toplevel")"

  write_script="set -e; test -f ${deploy_lock_dir}/owner && test \"\$(cat ${deploy_lock_dir}/owner)\" = ${deploy_lock_token} && ! test -e ${recovery_marker} && ! test -e $(deploy_recovery_complete_marker_path); install -d -m 0700 $(printf '%q' "$deploy_state_dir"); install -d $gcroot_dir_quoted; if test -e $gcroot_path_quoted && ! test -L $gcroot_path_quoted; then echo 'blocked: tested closure GC root is not a symlink' >&2; exit 1; fi; ln -sfn $toplevel_quoted $gcroot_path_quoted; tmp=\$(mktemp ${stamp_path_quoted}.tmp.XXXXXX); trap 'rm -f \"\$tmp\"' EXIT; printf 'version=1\\nsource_hash=%s\\ntoplevel=%s\\n' $source_hash_quoted $toplevel_quoted >\"\$tmp\"; chmod 0600 \"\$tmp\"; chown root:root \"\$tmp\"; mv -f \"\$tmp\" $stamp_path_quoted; trap - EXIT"
  target_command "sudo /bin/sh -c $(printf '%q' "$write_script")"
}

load_test_stamp() {
  local stamp_content stamp_tmp

  stamp_content="$(target_command "sudo cat $(printf '%q' "$test_stamp_path")")"
  stamp_tmp="$(mktemp)"
  chmod 0600 "$stamp_tmp"
  printf '%s\n' "$stamp_content" >"$stamp_tmp"
  if ! deploy_read_test_stamp "$stamp_tmp" stamped_source_hash stamped_toplevel; then
    rm -f "$stamp_tmp"
    return 1
  fi
  rm -f "$stamp_tmp"
}

run_health_gates() {
  echo "checking failed units"
  check_failed_units

  echo "checking public routes"
  if command -v curl >/dev/null 2>&1; then
    ./scripts/check-public-routes.sh --hostname "$HOSTNAME_ARG"
  else
    nix shell --inputs-from . nixpkgs#curl -c bash ./scripts/check-public-routes.sh --hostname "$HOSTNAME_ARG"
  fi

  if [[ "$homepage_canary_enabled" == "true" ]]; then
    echo "running authenticated service-access canary"
    target_command "sudo systemctl start homepage-canary.service"
    target_command "sudo /run/current-system/sw/bin/homepage-canary-assert"
  else
    echo "skipping authenticated service-access canary: homepage module is absent"
  fi
}

commit_boot_generation() {
  local toplevel="$1"
  local recovery_complete_marker recovery_marker

  assert_deploy_lock_owned
  recovery_complete_marker="$(deploy_recovery_complete_marker_path)"
  recovery_marker="$(deploy_recovery_marker_path)"
  boot_commit_started=true
  target_command "sudo /bin/sh -c $(printf '%q' "test -f ${deploy_lock_dir}/owner && test \"\$(cat ${deploy_lock_dir}/owner)\" = ${deploy_lock_token} && ! test -e ${recovery_marker} && ! test -e ${recovery_complete_marker} && $(printf '%q' "$target_nix_env") --profile /nix/var/nix/profiles/system --set $(printf '%q' "$toplevel") && $(printf '%q' "$toplevel/bin/switch-to-configuration") boot")"
}

deploy_main() {
local built_toplevel=""
local -a cmd=()

arm_deploy_transaction_traps

if [[ "$ACTION" == "test" ]]; then
  check_free_space
else
  echo "skipping build-host capacity gate: switch reuses the exact tested closure"
fi
check_target_free_space

echo "evaluating host ${HOSTNAME_ARG}"
nix eval --raw ".#nixosConfigurations.${HOSTNAME_ARG}.config.system.build.toplevel.drvPath" >/dev/null
homepage_canary_enabled="$(
  nix eval --json ".#nixosConfigurations.${HOSTNAME_ARG}.config.nixhomeserver.modules" \
    --apply 'modules: modules.homepage or false'
)"
source_hash="$(nix hash path .)"
deploy_validate_source_hash "$source_hash" || {
  echo "blocked: could not calculate a valid immutable repository hash" >&2
  false
}

if [[ "$DEBUG_MODE" == "true" ]]; then
  echo "running debug validation"
  nix shell --inputs-from . \
    nixpkgs#age nixpkgs#gawk nixpkgs#gitMinimal nixpkgs#gnugrep \
    nixpkgs#gnused nixpkgs#gnutar nixpkgs#jq nixpkgs#nodejs \
    nixpkgs#openssl nixpkgs#python3 nixpkgs#ripgrep nixpkgs#sqlite \
    nixpkgs#util-linux \
    -c bash ./scripts/validate-repo.sh --full
fi

acquire_deploy_lock
capture_previous_state

case "$ACTION" in
  test)
    build_nixos_rebuild_command cmd \
      build "$HOSTNAME_ARG" "$BUILD_LOCALLY" "$TARGET_HOST" "$BUILD_HOST"
    echo "building and copying the NixOS closure without activating it"
    built_toplevel="$("${cmd[@]}")"
    deploy_validate_toplevel_path "$built_toplevel" || {
      echo "blocked: nixos-rebuild returned an invalid NixOS closure path" >&2
      false
    }
    target_command "test -x $(printf '%q' "$built_toplevel/bin/switch-to-configuration")"
    assert_deploy_lock_owned
    schedule_rollback "24h"
    activation_started=true
    run_detached_activation "$built_toplevel" test tested-build
    activated_toplevel="$(target_readlink /run/current-system)"
    if [[ "$activated_toplevel" != "$built_toplevel" ]]; then
      echo "blocked: active closure differs from the closure returned by the passing build" >&2
      false
    fi
    run_health_gates
    write_test_stamp "$activated_toplevel"
    cancel_scheduled_rollback
    release_deploy_lock
    activation_started=false
    transaction_complete=true
    echo "recorded tested source ${source_hash} and closure ${activated_toplevel}"
    ;;
  switch)
    stamped_source_hash=""
    stamped_toplevel=""
    load_test_stamp
    if [[ "$source_hash" != "$stamped_source_hash" ]]; then
      echo "blocked: repository contents differ from the last passing test; run --action test again" >&2
      false
    fi
    target_command "test -x $(printf '%q' "$stamped_toplevel/bin/switch-to-configuration")"
    schedule_rollback "45m"
    activation_started=true
    run_detached_activation "$stamped_toplevel" test tested-switch
    activated_toplevel="$(target_readlink /run/current-system)"
    if [[ "$activated_toplevel" != "$stamped_toplevel" ]]; then
      echo "blocked: active closure differs from the closure recorded by the passing test" >&2
      false
    fi
    run_health_gates
    assert_deploy_lock_owned
    commit_boot_generation "$stamped_toplevel"
    cancel_scheduled_rollback
    release_deploy_lock
    boot_commit_started=false
    activation_started=false
    transaction_complete=true
    echo "committed tested closure ${stamped_toplevel} as the boot default"
    ;;
  *)
    echo "blocked: unsupported deploy action ${ACTION}" >&2
    false
    ;;
esac

clear_deploy_transaction_traps
[[ "$transaction_complete" == "true" ]]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  deploy_main
fi
