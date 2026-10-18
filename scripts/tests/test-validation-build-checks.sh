#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools jq rg

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
mkdir -p "$test_root/bin" "$test_root/tests" "$test_root/roots/current"
export VALIDATION_TEST_LOG="$test_root/calls"
export VALIDATE_REPO_TESTS_DIR="$test_root/tests"
export VALIDATE_REPO_ROOTS_DIR="$test_root/roots"
export REPO_NIX_EVAL_CACHE_DIR="$test_root/eval-cache"
printf 'previous passing outputs\n' >"$test_root/roots/current/previous"

cat >"$test_root/bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "$*" >>"$VALIDATION_TEST_LOG"
case "$*" in
  'config show substituters') echo 'https://cache.nixos.org' ;;
  'flake check --no-build') ;;
  *builtins.currentSystem*) echo x86_64-linux ;;
  'eval --json '*)
    [[ "${VALIDATION_TEST_EMPTY_WORKLIST:-0}" == 0 ]] || { echo '[]'; exit; }
    echo '["repo-policy","media-manager-test","media-manager-frontendDist"]'
    ;;
  'build '*)
    [[ "${VALIDATION_TEST_BUILD_FAIL:-0}" == 0 ]] || exit 42
    echo '[{"outputs":{"out":"/nix/store/00000000000000000000000000000000-check"}}]'
    ;;
  *) echo "Unexpected Nix command: $*" >&2; exit 1 ;;
esac
EOF
cat >"$test_root/tests/run-script-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'scripts %s\n' "$*" >>"$VALIDATION_TEST_LOG"
[[ "${VALIDATION_TEST_SCRIPT_FAIL:-0}" == 0 ]]
EOF
make_test_executable "$test_root/bin/nix" "$test_root/tests/run-script-tests.sh"
export PATH="$test_root/bin:$PATH"

run_gate() {
  : >"$VALIDATION_TEST_LOG"
  if ! bash "$TESTS_REPO_ROOT/scripts/validate-repo.sh" "$@" >"$test_root/output" 2>&1; then
    cat "$test_root/output" >&2
    return 1
  fi
}

run_gate
forbid_match "$VALIDATION_TEST_LOG" '^nix build' 'Lean validation must remain evaluation/script-only.'

if ! run_gate --build-checks --all-apps; then
  cat "$test_root/output"
  exit 1
fi
require_fixed "$VALIDATION_TEST_LOG" \
  '.#legacyPackages.x86_64-linux.nixhomeserverAllChecks.media-manager-test' \
  'Catalog validation must build Rust tests.'
require_fixed "$VALIDATION_TEST_LOG" \
  '.#legacyPackages.x86_64-linux.nixhomeserverAllChecks.media-manager-frontendDist' \
  'Catalog validation must build frontend checks.'
require_match "$VALIDATION_TEST_LOG" '^scripts --all-apps$' \
  'Build checks must retain the lean all-app script suite.'
forbid_match "$VALIDATION_TEST_LOG" 'repo-policy|hydraJobs|--full|flake check' \
  'Build checks must not recursively build repo-policy or opt into heavier suites.'

run_gate --build-checks
require_match "$VALIDATION_TEST_LOG" '^nix build .* --keep-going ' \
  'Independent builds must finish even when another check fails.'
require_fixed "$VALIDATION_TEST_LOG" '.#checks.x86_64-linux.media-manager-test' \
  'Host-scoped build checks must use the host check worklist.'
[[ "$(cat "$test_root/roots/current/previous")" == 'previous passing outputs' ]]
[[ "$(find "$test_root/roots" -type f | wc -l)" == 1 ]]

export VALIDATION_TEST_BUILD_FAIL=1
if run_gate --build-checks; then
  echo 'Build failures must fail validation.' >&2
  exit 1
fi
forbid_match "$VALIDATION_TEST_LOG" '^scripts ' 'Build failures must stop the gate.'
unset VALIDATION_TEST_BUILD_FAIL

export VALIDATION_TEST_SCRIPT_FAIL=1
if run_gate --build-checks; then
  echo 'Script failures must fail validation.' >&2
  exit 1
fi
unset VALIDATION_TEST_SCRIPT_FAIL

# Stop full mode at the script boundary so the real browser harness never runs.
# It must still build checks without --build-checks and select the full suite.
export VALIDATION_TEST_SCRIPT_FAIL=1
if run_gate --full --all-apps; then
  echo 'Full validation must propagate script failures.' >&2
  exit 1
fi
require_match "$VALIDATION_TEST_LOG" '^nix flake check --no-build$' 'Full validation must still evaluate the flake.'
require_match "$VALIDATION_TEST_LOG" '^nix build ' 'Full validation must still build checks.'
require_match "$VALIDATION_TEST_LOG" '^scripts --all-apps --full$' 'Full validation must still run the full script suite.'
unset VALIDATION_TEST_SCRIPT_FAIL

export VALIDATION_TEST_EMPTY_WORKLIST=1
if run_gate --build-checks; then
  echo 'An empty check worklist must fail validation.' >&2
  exit 1
fi
forbid_match "$VALIDATION_TEST_LOG" '^nix build' 'An empty worklist must never invoke a default Nix build.'

# Strict workstation configuration queries must use the remote-evaluation seam.
strict_query_log="$test_root/strict-query"
remote_eval_batch_json() {
  printf '%s\n' "$*" >>"$strict_query_log"
  if [[ "$*" == *'in "value"'* ]]; then
    printf '{"value":"value"}\n'
  else
    printf '{"value":1}\n'
  fi
}
strict_result="$(NIXHOMESERVER_REQUIRE_REMOTE=1 flake_eval_json 'in 1')"
[[ "$strict_result" == 1 ]] || {
  echo "Strict configuration query returned an unexpected result: $strict_result" >&2
  exit 1
}
[[ "$(cat "$strict_query_log")" == *'value='* ]] || {
  echo 'Strict configuration query bypassed remote_eval_batch_json.' >&2
  exit 1
}
strict_raw_result="$(NIXHOMESERVER_REQUIRE_REMOTE=1 flake_eval 'in "value"')"
[[ "$strict_raw_result" == value ]] || {
  echo "Strict raw configuration query returned an unexpected result: $strict_raw_result" >&2
  exit 1
}
strict_nix_calls="$(wc -l <"$VALIDATION_TEST_LOG")"
remote_eval_batch_json() { return 1; }
if NIXHOMESERVER_REQUIRE_REMOTE=1 flake_eval_json 'in 1' >/dev/null 2>&1; then
  echo 'Strict configuration query swallowed a remote evaluation failure.' >&2
  exit 1
fi
[[ "$(wc -l <"$VALIDATION_TEST_LOG")" == "$strict_nix_calls" ]] || {
  echo 'Strict configuration query fell back to local Nix evaluation.' >&2
  exit 1
}

# Strict full-worklist selection preserves every check except the existing
# repo-policy exclusion.
strict_names="$(printf '%s\n' repo-policy alpha-test beta-test disabled-app-test)"
filtered_names="$(strict_validation_check_names "$strict_names")"
[[ "$filtered_names" == $'alpha-test\nbeta-test\ndisabled-app-test' ]] || {
  echo "Strict worklist changed selected checks: $filtered_names" >&2
  exit 1
}

# Directly exercise the validator's strict server-root transaction functions in
# an isolated fake server state directory. Extracted definitions are the actual
# production functions; the remote transport and nix-store are fail-closed fakes.
root_functions="$test_root/strict-root-functions.sh"
for function_name in strict_stage_validation_roots strict_commit_validation_roots cleanup_tmpdirs run_derivation_checks run_shell_tests; do
  sed -n "/^${function_name}() {/,/^}/p" \
    "$TESTS_REPO_ROOT/scripts/validate-repo.sh" >>"$root_functions"
done
source "$root_functions"
strict_remote_log="$test_root/root-remote.log"
export strict_remote_log
remote_run() {
  local snippet="$1"
  shift
  printf 'remote-run %s\n' "${*:2}" >>"$strict_remote_log"
  bash -c "$snippet" x "$TESTS_REPO_ROOT" "$@"
}
full_mode=false
build_checks=false
strict_validation=1
pending_validation_roots_dir=''
pending_validation_roots_token=''
eval_cache_owned=''
eval_cache_dir=''
run_derivation_checks
[[ ! -s "$strict_remote_log" ]]
echo 'case no-build-route-does-not-stage-roots: PASS'
cat >"$test_root/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix-store %s\n' "$*" >>"$strict_remote_log"
[[ "${VALIDATION_TEST_STORE_FAIL:-0}" == 0 ]] || exit 43
[[ "$1" == --add-root && "$2" == /* && "$3" == --indirect && "$4" == --realise ]]
ln -s -- "$5" "$2"
EOF
make_test_executable "$test_root/bin/nix-store"
root_state="$test_root/server-state"
export VALIDATE_REPO_ROOTS_DIR="$root_state"
mkdir -p "$root_state/current" "$root_state/pending.keep"
printf 'prior current\n' >"$root_state/current/old-root"
printf 'unrelated pending\n' >"$root_state/pending.keep/keep"
outputs='[{"outputs":{"out":"/nix/store/11111111111111111111111111111111-new-check"}}]'
strict_stage_validation_roots "$root_state" success-1 "$outputs" >/dev/null
[[ -L "$root_state/pending.success-1/11111111111111111111111111111111-new-check" ]]
[[ -f "$root_state/current/old-root" ]]
[[ -f "$root_state/pending.keep/keep" ]]
strict_commit_validation_roots "$root_state" success-1 1 >/dev/null
[[ -L "$root_state/current/11111111111111111111111111111111-new-check" ]]
[[ ! -e "$root_state/pending.success-1" && ! -e "$root_state/previous.success-1" ]]
[[ ! -e "$root_state/current/old-root" ]]
echo 'case success-promotion: PASS'

# If pending-to-current promotion fails after the old current was moved aside,
# the validator restores that previous root before returning failure.
mkdir -p "$root_state/current"
printf 'rollback current\n' >"$root_state/current/rollback-root"
strict_stage_validation_roots "$root_state" commitfail-1 "$outputs" >/dev/null
real_mv="$(type -P mv)"
cat >"$test_root/bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -- && "${2:-}" == */pending.commitfail-1 && "${3:-}" == */current ]]; then
  exit 44
fi
exec "$VALIDATION_TEST_REAL_MV" "$@"
EOF
export VALIDATION_TEST_REAL_MV="$real_mv"
make_test_executable "$test_root/bin/mv"
if strict_commit_validation_roots "$root_state" commitfail-1 1 >/dev/null 2>&1; then
  echo 'A failed root promotion must fail the transaction.' >&2
  exit 1
fi
[[ "$(cat "$root_state/current/rollback-root")" == 'rollback current' ]]
[[ -d "$root_state/pending.commitfail-1" ]]
pending_validation_roots_token=commitfail-1
cleanup_tmpdirs
[[ ! -e "$root_state/pending.commitfail-1" ]]
rm "$test_root/bin/mv"
unset VALIDATION_TEST_REAL_MV
echo 'case promotion-rollback: PASS'

# A partial store-stage failure is cleaned only for its owned token; current
# roots and another run's pending tree remain untouched.
mkdir -p "$root_state/current" "$root_state/pending.failure-1"
printf 'passing current\n' >"$root_state/current/passing"
printf 'unrelated pending\n' >"$root_state/pending.keep/keep"
export VALIDATION_TEST_STORE_FAIL=1
if strict_stage_validation_roots "$root_state" failure-1 "$outputs" >/dev/null 2>&1; then
  echo 'A fake server store realization failure must fail root staging.' >&2
  exit 1
fi
unset VALIDATION_TEST_STORE_FAIL
strict_validation=1
pending_validation_roots_token=failure-1
pending_validation_roots_dir=''
eval_cache_owned=''
eval_cache_dir=''
cleanup_tmpdirs
[[ -f "$root_state/current/passing" ]]
[[ ! -e "$root_state/pending.failure-1" ]]
[[ -f "$root_state/pending.keep/keep" ]]
echo 'case store-stage-failure-isolation: PASS'

# A successful stage followed by a late full-suite failure runs the same EXIT
# cleanup path and must leave the previously committed roots intact.
strict_stage_validation_roots "$root_state" latefail-1 "$outputs" >/dev/null
pending_validation_roots_token=latefail-1
if (exit 47); then
  echo 'Late full-script failure control unexpectedly succeeded.' >&2
  exit 1
else
  late_script_status=$?
fi
[[ "$late_script_status" == 47 ]]
cleanup_tmpdirs
[[ -f "$root_state/current/passing" ]]
[[ ! -e "$root_state/pending.latefail-1" ]]
[[ -f "$root_state/pending.keep/keep" ]]
echo 'case late-script-failure-preserves-current: PASS'

# Exercise the actual strict full-check orchestration functions with fake build
# and script boundaries. A failed full script must trigger EXIT cleanup and skip
# both root commit and browser/e2e work; no local heavy tool is on this path.
strict_local_work_log="$test_root/strict-local-work.log"
export strict_local_work_log
strict_script_log="$test_root/strict-script.log"
export strict_script_log
failing_tests_dir="$test_root/failing-tests"
mkdir -p "$failing_tests_dir"
cat >"$failing_tests_dir/run-script-tests.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'script-suite %s\n' "$*" >>"$strict_script_log"
exit 42
EOF
make_test_executable "$failing_tests_dir/run-script-tests.sh"
if (
  source "$root_functions"
  strict_validation=1
  full_mode=true
  all_apps=false
  build_checks=false
  tests_dir="$failing_tests_dir"
  VALIDATE_REPO_ROOTS_DIR="$root_state"
  pending_validation_roots_dir=''
  pending_validation_roots_token=''
  eval_cache_owned=''
  eval_cache_dir=''
  trap cleanup_tmpdirs EXIT
  current_system() {
    printf 'current-system\n' >>"$strict_local_work_log"
    printf 'x86_64-linux\n'
  }
  build_derivation_attr() {
    printf 'synthetic-build %s\n' "$1" >>"$strict_local_work_log"
    validation_outputs_json='[{"outputs":{"out":"/nix/store/22222222222222222222222222222222-failed-full"}}]'
  }
  run_derivation_checks
  run_shell_tests
); then
  echo 'Strict full script failure control unexpectedly succeeded.' >&2
  exit 1
else
  strict_full_status=$?
fi
[[ "$strict_full_status" == 42 ]]
[[ "$(cat "$root_state/current/passing")" == 'passing current' ]]
[[ -f "$root_state/pending.keep/keep" ]]
[[ "$(cat "$strict_script_log")" == 'script-suite --full' ]]
if rg -q 'strict_commit_validation_roots|nix (eval|build)|cargo|playwright|browser' \
  "$strict_remote_log" "$strict_local_work_log"; then
  echo 'Strict full failure reached commit or a forbidden local heavy tool.' >&2
  exit 1
fi
echo 'case strict-full-failure-cleans-without-local-heavy-or-commit: PASS'

# A real synthetic TERM interrupts the process and exercises the installed EXIT
# cleanup trap, without reaching a server or altering other runs' roots.
strict_stage_validation_roots "$root_state" signal-1 "$outputs" >/dev/null
export -f remote_run
if (
  source "$root_functions"
  strict_validation=1
  pending_validation_roots_token=signal-1
  pending_validation_roots_dir=''
  eval_cache_owned=''
  eval_cache_dir=''
  trap cleanup_tmpdirs EXIT
  kill -TERM "$BASHPID"
); then
  echo 'Signal interruption control unexpectedly succeeded.' >&2
  exit 1
else
  signal_status=$?
fi
[[ "$signal_status" == 143 ]]
[[ -f "$root_state/current/passing" ]]
[[ ! -e "$root_state/pending.signal-1" ]]
[[ -f "$root_state/pending.keep/keep" ]]
echo 'case signal-cleanup-isolation: PASS'

# The validator's complete strict check-name boundary removes only repo-policy.
selected="$(strict_validation_check_names $'repo-policy\nalpha-test\nbeta-test\ndisabled-app-test')"
[[ "$selected" == $'alpha-test\nbeta-test\ndisabled-app-test' ]]
echo 'case strict-worklist-parity: PASS'

echo '✅ Validation build-check selection and failure propagation passed.'
