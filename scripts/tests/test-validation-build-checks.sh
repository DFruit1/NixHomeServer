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
  bash "$TESTS_REPO_ROOT/scripts/validate-repo.sh" "$@" >"$test_root/output" 2>&1
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

echo '✅ Validation build-check selection and failure propagation passed.'
