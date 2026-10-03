#!/usr/bin/env bash

# Proves the guarded debug-validation contract end to end against the real
# executor: the expensive full repository validation runs exactly once, on
# --action test only; switch reuses the attestation instead of rerunning it; and
# no failing or unproven path can leave a usable `debug_validated=true` stamp.
#
# Everything the deploy would otherwise touch is a fixture: `nix` is mocked so
# no flake, store, network, cache, or server is involved, and `target_command`
# is redirected at a temporary state directory. No real deploy is performed.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

export TARGET_HOST="admin@test.invalid"
export BUILD_HOST="admin@test.invalid"
export ACTION="test"
export HOSTNAME_ARG="test-host"
export DEBUG_MODE="false"
export BUILD_LOCALLY="false"
export BUILD_MODE="remote"
export LOCAL_BUILD_SLOTS="0"
export REMOTE_BUILD_SLOTS="auto"
export LOCAL_BUILD_CORES="0"
export REMOTE_BUILD_CORES="0"
export HOST_PLATFORM="x86_64-linux"
export BUILDER_SSH_PUBLIC_KEY="ssh-ed25519 AAAATESTBUILDERKEY builder@test"

source scripts/helpers/deploy-executor.sh
declare -F run_debug_full_validation >/dev/null
declare -F assert_debug_switch_attestation >/dev/null
declare -F write_test_stamp >/dev/null
declare -F load_test_stamp >/dev/null

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

# --- Mocked full validator -------------------------------------------------
#
# The executor resolves the validator through `nix shell ... -c bash
# ./scripts/validate-repo.sh --full`, so counting `nix` invocations that carry
# that exact command counts full-validator runs. This mock therefore exercises
# the real gate instead of replacing it.
validator_calls="$test_dir/validator-calls.log"
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"
cat >"$mock_bin/nix" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"scripts/validate-repo.sh --full"* ]]; then
  printf 'full-validator\n' >>"$TEST_DEBUG_VALIDATOR_CALLS"
  if [[ "${TEST_DEBUG_VALIDATOR_FAILS:-0}" == "1" ]]; then
    echo 'mock full validator: failing on purpose' >&2
    exit 1
  fi
  exit 0
fi
echo "unexpected nix invocation: $*" >&2
exit 97
EOF
make_test_executable "$mock_bin/nix"
export PATH="$mock_bin:$PATH"
export TEST_DEBUG_VALIDATOR_CALLS="$validator_calls"

count_validator_calls() {
  if [[ ! -f "$validator_calls" ]]; then
    printf '0\n'
  else
    wc -l <"$validator_calls" | tr -d ' '
  fi
}

reset_validator_calls() {
  : >"$validator_calls"
}

# A non-debug transaction never pays for the full validation.
reset_validator_calls
DEBUG_MODE="false"
ACTION="test"
run_debug_full_validation >/dev/null
if [[ "$(count_validator_calls)" != "0" ]]; then
  echo "❌ An ordinary test deploy ran the full debug validation."
  exit 1
fi

# A debug test runs it exactly once and records that it passed.
reset_validator_calls
DEBUG_MODE="true"
ACTION="test"
debug_full_validation_passed=false
run_debug_full_validation >/dev/null
if [[ "$(count_validator_calls)" != "1" ]]; then
  echo "❌ A debug test did not run the full validation exactly once."
  exit 1
fi
if [[ "$debug_full_validation_passed" != "true" ]]; then
  echo "❌ A completed debug test did not record the passing validation."
  exit 1
fi

# A debug switch reuses the recorded assurance instead of rerunning it.
reset_validator_calls
ACTION="switch"
run_debug_full_validation >/dev/null
if [[ "$(count_validator_calls)" != "0" ]]; then
  echo "❌ A debug switch reran the full validation instead of reusing the attestation."
  exit 1
fi

# The expensive validation still runs on a remote-allocation debug test: the
# gate depends on the action, not on where the build is allocated.
reset_validator_calls
ACTION="test"
BUILD_MODE="balanced"
LOCAL_BUILD_SLOTS="2"
run_debug_full_validation >/dev/null
if [[ "$(count_validator_calls)" != "1" ]]; then
  echo "❌ A remote-allocation debug test stopped running the full validation."
  exit 1
fi
BUILD_MODE="remote"
LOCAL_BUILD_SLOTS="0"

# A failing validator must never leave the transaction looking debug-validated.
# The call runs in this shell rather than a command substitution so the
# resulting flag is observable here, exactly as deploy_main would see it.
reset_validator_calls
export TEST_DEBUG_VALIDATOR_FAILS=1
set +e
run_debug_full_validation >"$test_dir/failing-validator.log" 2>&1
debug_failure_status=$?
set -e
if ((debug_failure_status == 0)); then
  echo "❌ A failing full validator reported success."
  cat "$test_dir/failing-validator.log"
  exit 1
fi
if [[ "$debug_full_validation_passed" == "true" ]]; then
  echo "❌ A failing full validator still recorded a passing validation."
  exit 1
fi
unset TEST_DEBUG_VALIDATOR_FAILS

# --- Stamp attestation -----------------------------------------------------
#
# target_command is redirected at a temporary state directory so the stamp and
# GC root land inside the fixture instead of /var/lib/nixhomeserver-deploy.
deploy_state_dir="$test_dir/deploy-state"
test_stamp_path="${deploy_state_dir}/last-tested-${HOSTNAME_ARG}.stamp"
test_gcroot_dir="$test_dir/gcroots"
test_gcroot_path="${test_gcroot_dir}/${HOSTNAME_ARG}"
deploy_lock_dir="$test_dir/deploy.lock"
deploy_lock_token="debug-attestation-owner"
deploy_lock_acquired=true
mkdir -p "$deploy_lock_dir" "$(dirname "$test_stamp_path")"
printf '%s\n' "$deploy_lock_token" >"$deploy_lock_dir/owner"

# Ownership is meaningless inside an unprivileged fixture, so shadow the
# chown with a no-op of the same arity rather than granting the suite
# privileges or mutating the script's control flow.
mkdir -p "$test_dir/no-op-bin"
cat >"$test_dir/no-op-bin/chown" <<'EOF'
#!/usr/bin/env bash
# Unprivileged fixture stand-in: accept the root-only ownership change and do
# nothing, so the rest of the stamp write still runs unchanged.
shift $#
EOF
make_test_executable "$test_dir/no-op-bin/chown"
target_command() {
  local encoded="${1#sudo /bin/sh -c }"
  local script=""
  eval "script=$encoded"
  if [[ "$script" == *"cat $test_stamp_path"* ]]; then
    cat "$test_stamp_path" 2>/dev/null
    return
  fi
  PATH="$test_dir/no-op-bin:$PATH" /bin/sh -c "$script"
}

stamped_toplevel="/nix/store/33333333333333333333333333333333-nixos-system-tested"
source_hash='sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA='

# An ordinary test stamps debug_validated=false and nothing more.
DEBUG_MODE="false"
source_hash="$source_hash"
write_test_stamp "$stamped_toplevel"
if ! rg -Fxq 'version=2' "$test_stamp_path" \
  || ! rg -Fxq 'debug_validated=false' "$test_stamp_path"; then
  echo "❌ An ordinary test did not record a version=2 stamp with debug_validated=false."
  cat "$test_stamp_path"
  exit 1
fi
if [[ "$(cat "$test_stamp_path")" != "$(printf 'version=2\nsource_hash=%s\ntoplevel=%s\ndebug_validated=false' "$source_hash" "$stamped_toplevel")" ]]; then
  echo "❌ The recorded stamp did not preserve the exact tested source and closure."
  cat "$test_stamp_path"
  exit 1
fi

# A debug switch accepts that unauthenticated stamp, because it asks for no
# extra assurance.
DEBUG_MODE="true"
stamped_source_hash=""
stamped_toplevel=""
stamped_debug_validated=""
load_test_stamp
if [[ "$stamped_source_hash" != "$source_hash" || "$stamped_debug_validated" != "false" ]]; then
  echo "❌ Switch did not parse the recorded stamp exactly."
  exit 1
fi
assert_debug_switch_attestation >/dev/null 2>&1 && {
  echo "❌ A --debug switch accepted a stamp without a debug attestation."
  exit 1
}
DEBUG_MODE="false"
assert_debug_switch_attestation
if [[ "$?" != "0" ]]; then
  echo "❌ An ordinary switch rejected a version=2 stamp."
  exit 1
fi

# A debug test that completed the full validation stamps a usable true
# attestation, and a --debug switch then accepts it.
DEBUG_MODE="true"
debug_full_validation_passed=true
write_test_stamp "$stamped_toplevel"
if ! rg -Fxq 'debug_validated=true' "$test_stamp_path"; then
  echo "❌ A debug test did not record a true debug attestation."
  cat "$test_stamp_path"
  exit 1
fi
stamped_debug_validated=""
load_test_stamp
assert_debug_switch_attestation

# A debug test whose validation failed must refuse to write any attestation,
# rather than writing a false one that a later --debug switch would accept.
debug_full_validation_passed=false
if write_failure_output="$(write_test_stamp "$stamped_toplevel" 2>&1)"; then
  echo "❌ A failed debug validation still recorded a stamp."
  exit 1
fi
if ! rg -Fq 'refusing to record a debug attestation' <<<"$write_failure_output"; then
  echo "❌ A failed debug validation did not explain why no attestation was recorded."
  echo "$write_failure_output"
  exit 1
fi
if [[ "$(cat "$test_stamp_path")" != "$(printf 'version=2\nsource_hash=%s\ntoplevel=%s\ndebug_validated=true' "$source_hash" "$stamped_toplevel")" ]]; then
  echo "❌ A failed debug validation overwrote the previously attested stamp."
  cat "$test_stamp_path"
  exit 1
fi

# Exercise malformed fields through both the real parser and the switch's
# stamp-loading gate. Presence must not be inferred from an empty value, and
# a final line without a newline must not be silently skipped.
valid_stamp="$(deploy_render_test_stamp "$source_hash" "$stamped_toplevel" true)"
assert_malformed_stamp_rejected() {
  local label="$1"
  local parsed_hash="unchanged" parsed_toplevel="unchanged" parsed_debug="unchanged"
  if deploy_read_test_stamp "$test_stamp_path" parsed_hash parsed_toplevel parsed_debug \
    >"$test_dir/parser-rejection.log" 2>&1; then
    echo "❌ Parser accepted malformed stamp: $label"
    exit 1
  fi
  if [[ "$parsed_hash" != unchanged || "$parsed_toplevel" != unchanged || "$parsed_debug" != unchanged ]]; then
    echo "❌ Rejected stamp modified parser outputs: $label"
    exit 1
  fi
  if (load_test_stamp && assert_debug_switch_attestation) \
    >"$test_dir/switch-rejection.log" 2>&1; then
    echo "❌ Debug switch gate accepted malformed stamp: $label"
    exit 1
  fi
}

for field in version source_hash toplevel debug_validated; do
  # Put the empty occurrence before the otherwise complete valid stamp.
  printf '%s=\n%s\n' "$field" "$valid_stamp" >"$test_stamp_path"
  assert_malformed_stamp_rejected "empty-then-valid $field"
  printf '%s\n%s=\n' "$valid_stamp" "$field" >"$test_stamp_path"
  assert_malformed_stamp_rejected "valid-then-empty $field"
  # Both nonempty and empty trailing duplicates must be read even at EOF.
  case "$field" in
    version) field_value=2 ;;
    source_hash) field_value="$source_hash" ;;
    toplevel) field_value="$stamped_toplevel" ;;
    debug_validated) field_value=true ;;
  esac
  printf '%s\n%s=%s' "$valid_stamp" "$field" "$field_value" >"$test_stamp_path"
  assert_malformed_stamp_rejected "unterminated duplicate $field"
  printf '%s\n%s=' "$valid_stamp" "$field" >"$test_stamp_path"
  assert_malformed_stamp_rejected "unterminated empty duplicate $field"
  # Also reject a single empty or missing required field.
  empty_stamp=""
  missing_stamp=""
  while IFS= read -r stamp_line; do
    if [[ "$stamp_line" == "$field="* ]]; then
      empty_stamp+="$field="$'\n'
    else
      empty_stamp+="$stamp_line"$'\n'
      missing_stamp+="$stamp_line"$'\n'
    fi
  done <<<"$valid_stamp"
  printf '%s' "$empty_stamp" >"$test_stamp_path"
  assert_malformed_stamp_rejected "single empty $field"
  printf '%s' "$missing_stamp" >"$test_stamp_path"
  assert_malformed_stamp_rejected "missing $field"
done

for invalid_line in '=value' '=' 'unknown=value' 'unknown=' 'malformed'; do
  for terminator in '' $'\n'; do
    printf '%s\n%s%s' "$valid_stamp" "$invalid_line" "$terminator" >"$test_stamp_path"
    assert_malformed_stamp_rejected "invalid trailing field [$invalid_line]"
  done
done

# A well-formed final field needs no newline, but it must still be validated.
printf '%s' "$valid_stamp" >"$test_stamp_path"
parsed_hash="" parsed_toplevel="" parsed_debug=""
deploy_read_test_stamp "$test_stamp_path" parsed_hash parsed_toplevel parsed_debug
[[ "$parsed_hash" == "$source_hash" && "$parsed_toplevel" == "$stamped_toplevel" && "$parsed_debug" == true ]]
load_test_stamp
assert_debug_switch_attestation

echo "✅ Deploy debug attestation tests passed."
