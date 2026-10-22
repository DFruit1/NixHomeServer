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
  # Checked before the currentSystem arm below: the batched worklist expression
  # contains that text, so an earlier raw-scalar arm would answer the batch.
  'eval --json '*)
    case "${VALIDATION_TEST_BATCH_MODE:-normal}" in
      normal)
        cat <<'JSON'
{"batchSystem":"x86_64-linux","batchNames":["repo-policy","media-manager-frontendDist","media-manager-test"]}
JSON
        ;;
      malformed)
        echo '{"batchSystem":"x86_64-linux","batchNames":"media-manager-test"}' ;;
      empty)
        echo '{"batchSystem":"x86_64-linux","batchNames":[]}' ;;
      nosystem)
        echo '{"batchNames":["media-manager-test"]}' ;;
      notobject)
        echo 'x86_64-linux' ;;
      *)
        echo "Unexpected batch mode: ${VALIDATION_TEST_BATCH_MODE}" >&2; exit 1 ;;
    esac
    ;;
  *builtins.currentSystem*) echo x86_64-linux ;;
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
if [[ "${NIXHOMESERVER_REQUIRE_REMOTE:-0}" == 1 ]]; then
  # The registered-suite consumer of the shared cache helper: this is the call
  # test-rclone-safety.sh makes, and in strict mode it may not evaluate here.
  source "$VALIDATION_TEST_TEST_COMMON"
  nix_eval_with_optional_cache raw '1 + 1' >"${VALIDATION_TEST_SUITE_OUT:?}"
fi
[[ "${VALIDATION_TEST_SCRIPT_FAIL:-0}" == 0 ]]
EOF
make_test_executable "$test_root/bin/nix" "$test_root/tests/run-script-tests.sh"
export PATH="$test_root/bin:$PATH"

run_gate() {
  : >"$VALIDATION_TEST_LOG"
  # Pin the evaluation target so the receipt names a host this test controls,
  # rather than whatever vars.nix currently resolves to on this machine.
  REMOTE_EVAL_HOST="dsaw@127.0.0.1" \
    bash "$TESTS_REPO_ROOT/scripts/validate-repo.sh" "$@" \
    >"$test_root/output" 2>&1
}

# --- heavy-step stand-ins ----------------------------------------------------
# A local `nix-store` must never run: registering a GC root is the one store
# operation full validation performs, and strict mode performs it on the server.
# The spy fails loudly so an accidental local realisation cannot pass silently.
cat >"$test_root/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
printf 'nix-store %s\n' "$*" >>"$VALIDATION_TEST_LOG"
exit 91
EOF
# The root snippets run for real below, as they would on the server, so they
# need their own store stand-in: it is only reachable from the emulated remote
# side and its calls are logged apart from the workstation's.
mkdir -p "$test_root/remote/bin"
cat >"$test_root/remote/bin/nix-store" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'nix-store %s\n' "$*" >>"${VALIDATION_TEST_REMOTE_LOG:?}"
[[ "$1" == '--add-root' && -n "${2:-}" && -n "${5:-}" ]] || exit 2
ln -sfn "$5" "$2"
EOF
# The Playwright suite is the one full-mode step that is not a shell snippet:
# it launches a browser. The seam keeps this transaction hermetic while still
# proving the gate reaches and orders the step.
cat >"$test_root/tests/homepage-e2e.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'e2e %s\n' "$*" >>"$VALIDATION_TEST_LOG"
exit "${VALIDATION_TEST_E2E_STATUS:-0}"
EOF
export VALIDATION_TEST_REMOTE_BIN="$test_root/remote/bin"
export VALIDATION_TEST_REMOTE_LOG="$test_root/remote-calls"
export VALIDATE_REPO_E2E_SCRIPT="$test_root/tests/homepage-e2e.sh"
make_test_executable "$test_root/bin/nix-store" "$test_root/remote/bin/nix-store" \
  "$test_root/tests/homepage-e2e.sh"

# Emulates every step of the remote-eval transport so the *remote* receipt can
# be asserted hermetically. Each arm answers one command the helper issues:
# the reachability probe, the namespace staging claim, the archive and
# expression uploads, the remote mktemp, and finally the evaluation itself.
# The last arm deliberately does not run the remote script (its tar/eval would
# need a real store), it just answers with the payload under test.
cat >"$test_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"$VALIDATION_TEST_LOG"
args="$*"
# Which of the strict run snippets this transfer is. The root transactions are
# the only ones whose filesystem effect is the thing under test, so they are the
# only ones the fixture replays; everything else is answered with a payload.
snippet_kind() {
  local file="$1"
  if grep -q 'nix flake check --no-build' "$file"; then
    echo flake-check
  elif grep -q -- '--add-root' "$file" && grep -q 'committed' "$file"; then
    echo roots-commit
  elif grep -q -- '--add-root' "$file"; then
    echo roots-stage
  elif grep -q 'pending\.\$token' "$file" && grep -q 'rm -rf' "$file"; then
    echo roots-cleanup
  elif grep -q 'nix "\$@"' "$file"; then
    echo suite-query
  else
    echo other
  fi
}
if [[ "$args" == *' bash -s -- '* ]]; then
  if [[ "$args" == *'nixhomeserver-remote-build'* ]]; then
    cat >/dev/null
    [[ "${VALIDATION_TEST_BUILD_FAIL:-0}" == 0 ]] || exit 42
    printf '%s\n' "$VALIDATION_TEST_BUILD_PAYLOAD"
    exit "${VALIDATION_TEST_REMOTE_BUILD_STATUS:-0}"
  fi
  if [[ "$args" == *'nixhomeserver-remote-run'* ]]; then
    kind=""
    if [[ -f "${VALIDATION_TEST_STAGED_DIR:?}/transferred.log" ]]; then
      kind="$(tail -n 1 "$VALIDATION_TEST_STAGED_DIR/transferred.log")"
    fi
    case "$kind" in
      roots-stage|roots-commit|roots-cleanup)
        # Replay the root transaction for real, the way the server would: the
        # transport script arrives on stdin, but the snippet itself is already
        # staged, and its arguments are the quoted tail of the command line.
        cat >/dev/null
        rest="${args#*bash -s -- }"
        eval "set -- $rest"
        remote_dir="$1"
        shift 3
        mkdir -p "$remote_dir"
        PATH="${VALIDATION_TEST_REMOTE_BIN:?}:$PATH" \
          VALIDATION_TEST_REMOTE_LOG="${VALIDATION_TEST_REMOTE_LOG:?}" \
          bash "${VALIDATION_TEST_STAGED_DIR}/run.sh" "$remote_dir" "$@"
        exit $?
        ;;
    esac
    cat >/dev/null
    printf '%s\n' "${VALIDATION_TEST_RUN_PAYLOAD:-strict-remote-snippet-value}"
    exit "${VALIDATION_TEST_RUN_STATUS:-0}"
  fi
  cat >/dev/null
  printf '%s\n' "$VALIDATION_TEST_BATCH_PAYLOAD"
  exit "${VALIDATION_TEST_REMOTE_EVAL_STATUS:-0}"
fi
if [[ "${VALIDATION_TEST_STRICT_TRANSPORT:-0}" == 1 ]]; then
  # A strict attempt asks the endpoint to attest itself and then binds the
  # transferred bytes by digest; both answers are emulated here so the public
  # validator's strict path can be asserted end to end.
  case "$args" in
    *'hostname -f'*) printf '%s\n' 'strict-buildhost.example.invalid'; exit 0 ;;
    *'uname -srm'*) printf '%s\n' 'Linux 6.1.0 x86_64'; exit 0 ;;
    *' stage nixhomeserver-remote-build'*)
      cat >/dev/null
      [[ "${VALIDATION_TEST_STAGE_STATUS:-0}" == 0 ]] || exit 1
      printf '%s\n' '/var/lib/nixhomeserver-deploy-archives/nixhomeserver-remote-build.a1b2c3d4.tar'
      exit 0
      ;;
    *' stage nixhomeserver-remote-run'*)
      cat >/dev/null
      [[ "${VALIDATION_TEST_STAGE_STATUS:-0}" == 0 ]] || exit 1
      printf '%s\n' '/var/lib/nixhomeserver-deploy-archives/nixhomeserver-remote-run.a1b2c3d4.tar'
      exit 0
      ;;
    *' stage '*)
      cat >/dev/null
      [[ "${VALIDATION_TEST_STAGE_STATUS:-0}" == 0 ]] || exit 1
      printf '%s\n' '/var/lib/nixhomeserver-deploy-archives/nixhomeserver-remote-eval.a1b2c3d4.tar'
      exit 0
      ;;
    *' remove '*) cat >/dev/null; exit "${VALIDATION_TEST_REMOVE_STATUS:-0}" ;;
    *'sha256sum -- '*)
      target="${args#*sha256sum -- }"
      target="${target#\'}"
      target="${target%\'}"
      staged="${VALIDATION_TEST_STAGED_DIR:?}/$(basename "$target")"
      [[ -f "$staged" ]] || exit 1
      printf '%s  %s\n' "$(sha256sum "$staged" | cut -d" " -f1)" "$target"
      exit 0
      ;;
    *'! -e '*) exit "${VALIDATION_TEST_ABSENT_STATUS:-0}" ;;
    *'rm -rf -- '*) exit "${VALIDATION_TEST_REMOVE_STATUS:-0}" ;;
    *'cat >'*)
      target="${args#*cat > }"
      target="${target#\'}"
      target="${target%\'}"
      case "$target" in
        /*) mkdir -p "${VALIDATION_TEST_STAGED_DIR:?}"
            staged="${VALIDATION_TEST_STAGED_DIR}/$(basename "$target")"
            cat >"$staged"
            # Record what kind of run snippet this was, in transfer order: the
            # order is the validator's own ordering evidence, and the kind is
            # what tells the run arm whether to replay the snippet.
            if [[ "$(basename "$target")" == 'run.sh' ]]; then
              printf '%s\n' "$(snippet_kind "$staged")" \
                >>"${VALIDATION_TEST_STAGED_DIR}/transferred.log"
            fi
            ;;
        *) cat >/dev/null ;;
      esac
      exit 0
      ;;
  esac
fi
case "$args" in
  *' true'*) exit 0 ;;
  *' stage nixhomeserver-remote-build'*) cat >/dev/null; echo /tmp/nixhomeserver-remote-build.stubarchive.a1b2c3d4.tar ;;
  *' stage '*) cat >/dev/null; echo /tmp/nixhomeserver-remote-eval.stubarchive.a1b2c3d4.tar ;;
  *'mktemp -d /tmp/nixhomeserver-remote-build'*) echo /tmp/nixhomeserver-remote-build.stubdir ;;
  *'mktemp -d'*) echo /tmp/nixhomeserver-remote-eval.stubdir ;;
  # The batched Nix expression arrives on stdin here, so log it: asserting that
  # the query was built correctly means reading the query that was sent. Only
  # the expression is logged; the repository archive that also arrives on stdin
  # would bury the call log under binary tar.
  *'query.nix'*) cat >>"$VALIDATION_TEST_LOG"; exit 0 ;;
  *'cat >'*) cat >/dev/null; exit 0 ;;
  *) exit 1 ;;
esac
EOF
make_test_executable "$test_root/bin/ssh"

# The transport mode belongs to this fixture, not to the invoking shell. Every
# run below starts from the default remote path, and the one deliberate local
# probe re-assigns it at its own call site, where the opt-out is visible as the
# thing under test. Without this isolation an ambient `REMOTE_EVAL=0` silently
# rewrites every assertion about the remote receipt into a local one.
export REMOTE_EVAL=1
export VALIDATION_TEST_BATCH_PAYLOAD='{"batchSystem":"x86_64-linux","batchNames":["repo-policy","media-manager-frontendDist","media-manager-test"]}'
export VALIDATION_TEST_BUILD_PAYLOAD='[{"outputs":{"out":"/nix/store/00000000000000000000000000000000-check"}}]'
# The staged remote build is the only build transport now; every "was a build
# attempted" assertion matches this instead of a local `nix build`.
remote_build_re='bash -s -- .*nixhomeserver-remote-build'
export PATH="$test_root/bin:$PATH"

run_gate
forbid_match "$VALIDATION_TEST_LOG" "$remote_build_re" 'Lean validation must remain evaluation/script-only.'

if ! run_gate --build-checks --all-apps; then
  cat "$test_root/output"
  exit 1
fi
# Every exclusion must be announced with the class it belongs to and the direct
# path that keeps its coverage, so a reviewer sees a relocation rather than a
# silent skip.
require_match "$test_root/output" \
  'Building repo-policy is excluded.*PATH into the invoking user' \
  'Every sandbox exclusion must state the class it belongs to.'
require_fixed "$test_root/output" \
  'It runs directly here via scripts/tests/run-script-tests.sh' \
  'Every sandbox exclusion must name the direct path that keeps its coverage.'
require_fixed "$VALIDATION_TEST_LOG" \
  '.#legacyPackages.x86_64-linux.nixhomeserverAllChecks.media-manager-test' \
  'Excluding one check must not disturb the rest of the selected set.'
require_fixed "$VALIDATION_TEST_LOG" \
  '.#legacyPackages.x86_64-linux.nixhomeserverAllChecks.media-manager-frontendDist' \
  'Excluding one check must not disturb the rest of the selected set.'
require_match "$VALIDATION_TEST_LOG" '^scripts --all-apps$' \
  'Build checks must retain the lean all-app script suite.'
# Scoped to the build command and the script suite: the evaluated worklist
# legitimately names repo-policy, since naming a check is what gets it excluded.
forbid_match "$VALIDATION_TEST_LOG" "bash -s -- .*nixhomeserver-remote-build.*(--full|hydraJobs|flake check|repo-policy)" \
  'Build checks must not recursively build repo-policy or opt into heavier suites.'
forbid_match "$VALIDATION_TEST_LOG" '^scripts .*(--full|hydraJobs)' \
  'Build checks must not opt into a heavier script suite.'

# The default exclusion table is the entire policy surface. Compare the checks
# the gate builds against the evaluated worklist minus that table, so widening
# the table is a visible diff rather than a silent loss of coverage.
exclusions_default="$(bash "$TESTS_REPO_ROOT/scripts/validate-repo.sh" \
  --print-sandbox-exclusions)"
[[ "$exclusions_default" == 'repo-policy|scripts/tests/run-script-tests.sh' ]]
excluded_names="$(cut -d'|' -f1 <<<"$exclusions_default" | sort)"
expected_names="$(comm -23 \
  <(printf '%s\n' media-manager-frontendDist media-manager-test repo-policy | sort) \
  <(printf '%s\n' "$excluded_names"))"
[[ "$expected_names" == $'media-manager-frontendDist\nmedia-manager-test' ]]
for name in $(printf '%s\n' "$expected_names"); do
  require_fixed "$VALIDATION_TEST_LOG" \
    ".#legacyPackages.x86_64-linux.nixhomeserverAllChecks.${name}" \
    "Every non-excluded check (${name}) must still be built."
done

# An exclusion that cannot name a working direct validation path is not a
# relocation, it is a skip: the gate must fail rather than drop the coverage.
printf '%s\n' 'repo-policy|scripts/tests/does-not-exist.sh' \
  >"$test_root/exclusions-broken"
export VALIDATE_REPO_SANDBOX_EXCLUSIONS="$test_root/exclusions-broken"
if run_gate --build-checks; then
  echo 'An exclusion without a working direct validation path must fail validation.' >&2
  exit 1
fi
require_match "$test_root/output" 'direct validation path is missing or not executable' \
  'A broken exclusion must name the direct path it could not find.'
forbid_match "$VALIDATION_TEST_LOG" '^scripts ' \
  'A broken exclusion must stop the gate, not fall through to the script suite.'
forbid_match "$VALIDATION_TEST_LOG" "$remote_build_re" \
  'A broken exclusion must stop before building anything.'
forbid_match "$VALIDATION_TEST_LOG" ' bash -s -- ' \
  'A broken exclusion must stop before the worklist is even evaluated.'

# An exclusion entry with no direct path at all is equally a silent skip.
printf '%s\n' 'repo-policy' >"$test_root/exclusions-empty"
export VALIDATE_REPO_SANDBOX_EXCLUSIONS="$test_root/exclusions-empty"
if run_gate --build-checks; then
  echo 'An exclusion without a direct validation path must fail validation.' >&2
  exit 1
fi
require_match "$test_root/output" 'direct validation path is missing or not executable' \
  'An exclusion with no path must be rejected rather than accepted.'
forbid_match "$VALIDATION_TEST_LOG" ' bash -s -- ' \
  'An exclusion with no path must stop before the worklist is evaluated.'
unset VALIDATE_REPO_SANDBOX_EXCLUSIONS

# --- an exclusion may only relocate a known check onto its known path --------
#
# An executable file is not a validation path. Anything in the tree satisfies
# `-x`, and the gate's own success message would be the only thing that changed:
# the check's coverage is dropped while the run still reports a pass.
probe_exclusion_rejection() {
  local label="$1" row="$2"
  printf '%s\n' "$row" >"$test_root/exclusions-unrelated"
  export VALIDATE_REPO_SANDBOX_EXCLUSIONS="$test_root/exclusions-unrelated"
  if run_gate --build-checks; then
    echo "❌ An exclusion that cannot preserve coverage must fail validation: ${label}" >&2
    cat "$test_root/output" >&2
    exit 1
  fi
  require_match "$test_root/output" 'is excluded from derivation builds' \
    "The rejection must name the exclusion it refused (${label})."
  forbid_match "$VALIDATION_TEST_LOG" "$remote_build_re" \
    "A rejected exclusion must stop before building anything (${label})."
  forbid_match "$VALIDATION_TEST_LOG" '^scripts ' \
    "A rejected exclusion must stop before the script suite (${label})."
  forbid_match "$VALIDATION_TEST_LOG" ' bash -s -- ' \
    "A rejected exclusion must stop before the worklist is evaluated (${label})."
}

# An unrelated executable named for a known check is the closest resemblance of
# the real relocation, and must still be refused.
probe_exclusion_rejection 'helper-as-known-path' \
  'repo-policy|scripts/tests/test-common.sh'
require_match "$test_root/output" \
  'repo-policy is excluded from derivation builds onto an unrelated direct path.*test-common.sh' \
  'A known check excluded onto an unrelated executable must name the rejection.'
require_fixed "$test_root/output" \
  'Its coverage-preserving path is scripts/tests/run-script-tests.sh' \
  'The rejection must name the path that would preserve coverage.'

# A check with no place in the table cannot be excluded at all: only a check
# with its own remote-build failure evidence may be relocated.
probe_exclusion_rejection 'unknown-check-with-helper' \
  'media-manager-test|scripts/tests/test-common.sh'
require_match "$test_root/output" \
  'media-manager-test is excluded from derivation builds but is not a known sandbox-excluded check' \
  'An unlisted check must be rejected as unknown, not accepted.'

# Reusing a known path for an unrelated check is the same silent skip: the path
# preserves coverage for the check it was proven for, not for any check.
probe_exclusion_rejection 'known-path-for-unrelated-check' \
  'media-manager-test|scripts/tests/run-script-tests.sh'
require_match "$test_root/output" \
  'media-manager-test is excluded from derivation builds but is not a known sandbox-excluded check' \
  'A known path must not authorize an unrelated check.'
unset VALIDATE_REPO_SANDBOX_EXCLUSIONS

run_gate --build-checks
require_match "$VALIDATION_TEST_LOG" "bash -s -- .*nixhomeserver-remote-build.*--keep-going" \
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
require_match "$VALIDATION_TEST_LOG" "$remote_build_re" 'Full validation must still build checks.'
require_match "$VALIDATION_TEST_LOG" '^scripts --all-apps --full$' 'Full validation must still run the full script suite.'
unset VALIDATION_TEST_SCRIPT_FAIL

# --- one batched worklist query ---------------------------------------------
#
# The gate used to ask `nix eval` twice on the workstation: once for
# builtins.currentSystem, once for the check names. Both must now come from a
# single batched query, and neither may still cost a local evaluation.
run_gate --build-checks
if [[ "$(grep -c 'bash -s -- .*nixhomeserver-remote-eval' "$VALIDATION_TEST_LOG")" != "1" ]]; then
  echo '❌ The check worklist must cost exactly one batched evaluation.' >&2
  cat "$VALIDATION_TEST_LOG" >&2
  exit 1
fi
forbid_match "$VALIDATION_TEST_LOG" '^nix eval --json --impure --expr' \
  'The batched worklist must not also run a local evaluation.'
forbid_match "$VALIDATION_TEST_LOG" '^nix eval --impure --raw' \
  'The host system must come from the batch, not a separate raw evaluation.'
require_fixed "$VALIDATION_TEST_LOG" \
  'builtins.attrNames f.checks.${builtins.currentSystem}' \
  'The batched query must ask for the host-scoped check worklist.'
require_match "$test_root/output" \
  'Evaluated the check worklist on .* in one batched query' \
  'The gate must report where the worklist was evaluated.'
require_fixed "$test_root/output" 'media-manager-frontendDist, media-manager-test, repo-policy' \
  'The evaluation receipt must name the checks it actually selected.'
require_fixed "$test_root/output" 'on dsaw@127.0.0.1' \
  'The receipt must name the host the helper actually connected to.'
require_match "$test_root/output" '; 3 checks, in one batched query\.' \
  'The receipt must count checks, not characters.'

run_gate --build-checks --all-apps
require_fixed "$VALIDATION_TEST_LOG" \
  'builtins.attrNames f.legacyPackages.${builtins.currentSystem}.nixhomeserverAllChecks' \
  'The all-app batch must ask for the repository-wide check worklist.'
require_fixed "$VALIDATION_TEST_LOG" \
  '.#legacyPackages.x86_64-linux.nixhomeserverAllChecks.media-manager-test' \
  'The all-app worklist must still drive the build targets.'
forbid_match "$VALIDATION_TEST_LOG" \
  'builtins\.attrNames f\.checks\.\$\{builtins\.currentSystem\}' \
  'A batch must not ask for the host-scoped attr on the all-app path.'

# REMOTE_EVAL=0 must keep the gate honest on a serverless workstation: the same
# worklist, the same filtering, and a receipt that says where it ran.
REMOTE_EVAL=0 run_gate --build-checks
require_match "$test_root/output" \
  'Evaluated the check worklist on this workstation \(.*media-manager-test' \
  'REMOTE_EVAL=0 must report that the worklist stayed local.'
forbid_match "$VALIDATION_TEST_LOG" 'bash -s -- .*nixhomeserver-remote-eval' \
  'REMOTE_EVAL=0 must never evaluate the worklist over SSH.'
require_fixed "$VALIDATION_TEST_LOG" \
  'builtins.attrNames f.checks.${builtins.currentSystem}' \
  'REMOTE_EVAL=0 must still use the same batched expression.'
require_fixed "$VALIDATION_TEST_LOG" '.#checks.x86_64-linux.media-manager-test' \
  'REMOTE_EVAL=0 must build exactly the same checks as the remote path.'

# --- a malformed payload must never shrink the check set ---------------------
#
# This is the whole risk of the change: a worklist evaluation that returns
# something unexpected must stop the gate. Silently accepting it would let a
# broken offload look like a passing validation that checked almost nothing.
good_payload="$VALIDATION_TEST_BATCH_PAYLOAD"
# Each of these is a way the transport could answer without answering the
# question. None of them may be read as a worklist.
for bad_payload in \
  '{"batchSystem":"x86_64-linux","batchNames":"media-manager-test"}' \
  '{"batchSystem":"x86_64-linux","batchNames":[]}' \
  '{"batchNames":["media-manager-test"]}' \
  '{"batchSystem":"x86_64-linux"}' \
  '{"batchSystem":"x86_64-linux","batchNames":[42]}' \
  'x86_64-linux' \
  '' ; do
  export VALIDATION_TEST_BATCH_PAYLOAD="$bad_payload"
  if run_gate --build-checks; then
    echo "❌ A malformed worklist payload must fail validation: ${bad_payload:-<empty>}" >&2
    cat "$test_root/output" >&2
    exit 1
  fi
  require_match "$test_root/output" 'malformed payload' \
    'A malformed payload must be reported as malformed, not silently accepted.'
  forbid_match "$VALIDATION_TEST_LOG" "$remote_build_re" \
    'A malformed payload must stop before building anything.'
  forbid_match "$VALIDATION_TEST_LOG" '^scripts ' \
    'A malformed payload must stop before the script suite.'
done
export VALIDATION_TEST_BATCH_PAYLOAD="$good_payload"

# --- a check name is one attr path on one line -------------------------------
#
# The worklist is serialized newline-delimited and each name becomes
# `.#<attr>.<name>`. A name that smuggled a newline would split into extra
# lines, and a line reading exactly `repo-policy` would match the exclusion
# table: the real check is never built, the exclusion is announced as a covered
# relocation, and the run reports a pass. A newline-bearing name must therefore
# be rejected as a malformed payload before any build or script.
for wrapped_name in $'\nrepo-policy' $'repo-policy\n' $'repo-policy\nmedia-manager-test'; do
  wrapped_payload="$(jq -cn --arg wrapped "$wrapped_name" \
    '{batchSystem:"x86_64-linux",batchNames:["media-manager-frontendDist",$wrapped,"media-manager-test"]}')"
  export VALIDATION_TEST_BATCH_PAYLOAD="$wrapped_payload"
  if run_gate --build-checks; then
    printf '❌ A newline-bearing check name must fail validation: %q\n' "$wrapped_name" >&2
    cat "$test_root/output" >&2
    exit 1
  fi
  require_match "$test_root/output" 'malformed payload' \
    'A newline-bearing check name must be reported as a malformed payload.'
  forbid_match "$test_root/output" 'Building repo-policy is excluded' \
    'A wrapped name must never be accepted as the excluded check.'
  forbid_match "$VALIDATION_TEST_LOG" "$remote_build_re" \
    'A newline-bearing check name must stop before building anything.'
  forbid_match "$VALIDATION_TEST_LOG" '^scripts ' \
    'A newline-bearing check name must stop before the script suite.'
done
export VALIDATION_TEST_BATCH_PAYLOAD="$good_payload"

# A remote evaluation that fails outright is not a worklist either. The helper
# falls back to a local evaluation, so the gate must still finish the build —
# but it must report the failure and must never claim a remote receipt.
export VALIDATION_TEST_REMOTE_EVAL_STATUS=1
if ! run_gate --build-checks; then
  cat "$test_root/output" >&2
  echo '❌ A failing remote evaluation must fall back, not fail the gate.' >&2
  exit 1
fi
require_match "$test_root/output" 'remote evaluation failed' \
  'A failing remote evaluation must be reported with its cause.'
require_match "$test_root/output" \
  'Evaluated the check worklist on this workstation' \
  'A failed remote evaluation must produce a local receipt.'
forbid_match "$test_root/output" 'in one batched query' \
  'A failed remote evaluation must never claim a remote receipt.'
require_fixed "$VALIDATION_TEST_LOG" '.#checks.x86_64-linux.media-manager-test' \
  'A failed remote evaluation must still build the whole worklist locally.'
unset VALIDATION_TEST_REMOTE_EVAL_STATUS

# --- an unreachable server must not silently move the worklist ---------------
#
# The helper's own contract is that it warns and falls back to a local
# evaluation. What the gate adds is that the fallback is *visible*: a run that
# quietly did the slow thing on the workstation has to say so.
mv "$test_root/bin/ssh" "$test_root/bin/ssh.stub-unreachable"
cat >"$test_root/bin/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ssh %s\n' "$*" >>"$VALIDATION_TEST_LOG"
exit 255
EOF
make_test_executable "$test_root/bin/ssh"

if ! run_gate --build-checks; then
  cat "$test_root/output" >&2
  echo 'An unreachable build server must fall back, not fail the gate.' >&2
  exit 1
fi
require_match "$test_root/output" 'falling back to local evaluation' \
  'An unreachable build server must be reported, not hidden.'
require_match "$test_root/output" \
  'Evaluated the check worklist on this workstation' \
  'An unreachable build server must produce a local receipt, not a remote one.'
forbid_match "$test_root/output" 'in one batched query' \
  'A local fallback must never claim a remote receipt.'
# The fallback must still build the full worklist: a transport failure narrows
# nothing.
require_fixed "$VALIDATION_TEST_LOG" '.#checks.x86_64-linux.media-manager-test' \
  'A local fallback must still build every check the worklist named.'
require_fixed "$VALIDATION_TEST_LOG" '.#checks.x86_64-linux.media-manager-frontendDist' \
  'A local fallback must still build every check the worklist named.'
mv "$test_root/bin/ssh.stub-unreachable" "$test_root/bin/ssh"

# --- the strict route through the same public validator ----------------------
#
# Strict mode is a promise about the whole gate: the source is the declared
# commit, and no heavy step runs on this workstation. The checks above already
# prove the ordinary selection, batching and failure behaviour, so this section
# composes the strict route on top of it -- suite, worklist evaluation, build,
# and root staging -- against the same hermetic transport.
export VALIDATION_TEST_TEST_COMMON="$TESTS_REPO_ROOT/scripts/tests/test-common.sh"

strict_repo="$test_root/strict-repo"
mkdir -p "$strict_repo/scripts" "$strict_repo/.tmp"
printf '.tmp/\n' >"$strict_repo/.gitignore"
printf 'strict fixture\n' >"$strict_repo/tracked.txt"
git -C "$strict_repo" init -q
git -C "$strict_repo" -c user.email=strict@example.invalid -c user.name=strict add -A
git -C "$strict_repo" -c user.email=strict@example.invalid -c user.name=strict \
  commit -qm 'strict fixture source'
strict_head="$(git -C "$strict_repo" rev-parse HEAD)"
strict_tree="$(git -C "$strict_repo" rev-parse 'HEAD^{tree}')"
strict_evidence="$strict_repo/.tmp/evidence"
mkdir -p "$strict_evidence" "$test_root/staged"
# The root transaction needs its own state directory: a passing --full run
# releases, and a retaining one promotes, the GC roots recorded there.
strict_root_state="$test_root/strict-roots"
mkdir -p "$strict_root_state/current"
export REMOTE_RUN=1

run_strict_gate() {
  : >"$VALIDATION_TEST_LOG"
  : >"$test_root/staged/transferred.log"
  # A cached suite evaluation would skip the remote boundary this fixture has to
  # observe, so every strict run starts from a cold cache.
  rm -rf "$REPO_NIX_EVAL_CACHE_DIR"
  NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_STRICT_REPO_ROOT="$strict_repo" \
    NIXHOMESERVER_EXPECTED_HEAD="$strict_head" \
    NIXHOMESERVER_EXPECTED_TREE="$strict_tree" \
    NIXHOMESERVER_EVIDENCE_DIR="$strict_evidence" \
    NIXHOMESERVER_TEST_HOST='server' \
    VALIDATION_TEST_STRICT_TRANSPORT=1 \
    VALIDATION_TEST_STAGED_DIR="$test_root/staged" \
    VALIDATION_TEST_SUITE_OUT="$test_root/suite-eval.out" \
    VALIDATE_REPO_ROOTS_DIR="$strict_root_state" \
    VALIDATE_RETAIN_OUTPUT_ROOTS="${strict_retain_roots:-0}" \
    REMOTE_EVAL_HOST='dsaw@127.0.0.1' \
    HERMES_KANBAN_TASK='t_validation_strict' \
    HERMES_KANBAN_BOARD='nixhomeserver' \
    HERMES_KANBAN_RUN_ID='1' \
    bash "$TESTS_REPO_ROOT/scripts/validate-repo.sh" "$@" \
    >"$test_root/output" 2>&1
}

strict_receipts() {
  find "$strict_evidence" -maxdepth 1 -name '*.receipt.json' -print | sort
}

strict_manifest="$(NIXHOMESERVER_EXPECTED_HEAD="$strict_head" \
  NIXHOMESERVER_STRICT_REPO_ROOT="$strict_repo" strict_tree_manifest "$strict_repo")" \
  || { echo '❌ Could not compute the strict fixture manifest.' >&2; exit 1; }

if ! run_strict_gate --build-checks; then
  cat "$test_root/output" >&2
  echo '❌ The strict route must pass the same gate the ordinary route passes.' >&2
  exit 1
fi

# Every heavy step is remote: the workstation's own nix may only answer cheap
# configuration questions.
forbid_match "$VALIDATION_TEST_LOG" '^nix eval ' \
  'Strict mode must not evaluate the configuration on this workstation.'
forbid_match "$VALIDATION_TEST_LOG" '^nix build ' \
  'Strict mode must not build on this workstation.'
forbid_match "$VALIDATION_TEST_LOG" '^nix flake ' \
  'Strict mode must not run flake checks on this workstation.'
require_fixed "$VALIDATION_TEST_LOG" 'stage nixhomeserver-remote-eval' \
  'Strict evaluation must stage its source through the receipted transport.'
require_fixed "$VALIDATION_TEST_LOG" 'stage nixhomeserver-remote-build' \
  'Strict builds must stage their source through the receipted transport.'

# The selected configuration host has to travel with the query: the remote shell
# does not inherit it, so a query that silently evaluated another host would look
# exactly like a passing one.
require_match "$VALIDATION_TEST_LOG" 'query\.nix server' \
  'The selected configuration host must travel with the strict query.'

# Strict root staging only runs for a full gate; the --full transaction below
# exercises it through this same public validator.

# Each attempt leaves a receipt that names the commit, the manifest it verified
# and the cleanup it observed.
receipt_count=0
receipt_phases=""
while IFS= read -r receipt_file; do
  [[ -n "$receipt_file" ]] || continue
  receipt_count=$((receipt_count + 1))
  receipt_phases+="$(jq -r '.phase // "unknown"' "$receipt_file") "
  jq -e --arg manifest "$strict_manifest" --arg head "$strict_head" --arg tree "$strict_tree" '
    .commit == $head
    and .tree == $tree
    and .canonical_manifest_sha256 == $manifest
    and .exit_status == 0
    and .cleanup == "success"
    and (.archive_sha256 | test("^[0-9a-f]{64}$"))
  ' "$receipt_file" >/dev/null \
    || { echo "❌ A strict receipt is not attributable: $(cat "$receipt_file")" >&2; exit 1; }
done < <(strict_receipts)
if ((receipt_count < 2)); then
  echo "❌ The strict route wrote only ${receipt_count} receipts (${receipt_phases:-none}); evaluation and build must be accounted for." >&2
  exit 1
fi
for phase_family in eval build; do
  [[ " $receipt_phases " == *" ${phase_family}-"* ]] || {
    echo "❌ No ${phase_family} receipt was written; strict phases were: ${receipt_phases}" >&2
    exit 1
  }
done

# The registered suite's shared-cache query is the exact call the rclone safety
# suite makes, and it must have been answered remotely.
require_fixed "$test_root/suite-eval.out" 'strict-remote-snippet-value' \
  'A registered suite query must be answered by the remote boundary in strict mode.'
# The stub runner writes this marker, so its presence proves the registered
# suite path ran under the strict gate.
require_fixed "$VALIDATION_TEST_LOG" 'scripts ' \
  'Strict mode must still run the registered suites.'

echo '  ✅ the strict route composes through the public validator'

# A staging failure is a refusal, never a local fallback: the gate stops, and no
# receipt claims a success it never observed.
export VALIDATION_TEST_STAGE_STATUS=1
if run_strict_gate --build-checks; then
  echo '❌ A strict gate whose staging failed must not report a pass.' >&2
  cat "$test_root/output" >&2
  exit 1
fi
forbid_match "$VALIDATION_TEST_LOG" '^nix eval ' \
  'A strict staging failure must not fall back to a workstation evaluation.'
forbid_match "$test_root/output" 'falling back to local evaluation' \
  'A strict staging failure must be a refusal, not a silent local fallback.'
require_match "$test_root/output" 'could not stage|staging' \
  'A strict staging failure must say what failed.'
unset VALIDATION_TEST_STAGE_STATUS

echo '  ✅ a strict staging failure refuses instead of falling back'

# --- the strict --full validator transaction ---------------------------------
#
# --full is the mode a whole-gate run uses and the only one that stages, retains
# and releases the GC roots a passing validation depends on. This drives that
# transaction through the same public validator and the same hermetic transport:
# the two root snippets are replayed for real against a scratch root state (their
# filesystem effect is the thing under test), while every evaluation, build and
# browser step stays remote or stubbed. Each failure has to propagate and leave
# the previous passing roots exactly where they are.
strict_fail() { echo "❌ $*" >&2; exit 1; }

prior_root="$strict_root_state/current/previous-check"
seed_prior_root() {
  install -d -m 0700 "$strict_root_state/current"
  ln -sfn '/nix/store/previous-check-output' "$prior_root"
}
pending_roots() {
  find "$strict_root_state" -mindepth 1 -maxdepth 1 -name 'pending.*' -print 2>/dev/null | wc -l
}
transferred_snippets() { cat "$test_root/staged/transferred.log"; }
require_no_local_heavy() {
  local label="$1"
  forbid_match "$VALIDATION_TEST_LOG" '^nix (eval|build|flake|develop|shell) ' \
    "${label}: a heavy Nix step ran on this workstation"
  forbid_match "$VALIDATION_TEST_LOG" '^nix-store ' \
    "${label}: a GC root was registered on this workstation"
}
# The registered suite runs here, against the parent checkout. Nothing about
# this transaction may move that checkout's provenance.
parent_head="$(git -C "$TESTS_REPO_ROOT" rev-parse HEAD)"
parent_tree="$(git -C "$TESTS_REPO_ROOT" rev-parse 'HEAD^{tree}')"
parent_status="$(git -C "$TESTS_REPO_ROOT" status --short -uno)"

# A passing --full run with the default release semantics: the worklist is
# evaluated and built remotely, the roots are staged and released, the suites run
# here, and the browser step is reached.
seed_prior_root
: >"$VALIDATION_TEST_REMOTE_LOG"
if ! run_strict_gate --full; then
  cat "$test_root/output" >&2
  strict_fail 'The strict --full transaction must pass on the hermetic transport.'
fi
require_fixed "$test_root/output" \
  'media-manager-frontendDist, media-manager-test, repo-policy' \
  'A strict --full run must evaluate the complete worklist, not a narrowed one.'
require_fixed "$VALIDATION_TEST_LOG" 'checks.x86_64-linux' \
  'A strict --full run must build the whole check attr on the server.'
require_fixed "$VALIDATION_TEST_LOG" 'scripts --full' \
  'A strict --full run must run the registered suite with full selection.'
require_match "$VALIDATION_TEST_LOG" '^e2e ' \
  'A strict --full run must reach the browser step.'
forbid_match "$VALIDATION_TEST_LOG" 'scripts --full --all-apps' \
  'A strict --full run without --all-apps must keep the enabled-app scope.'
require_no_local_heavy 'the strict --full transaction'
[[ -n "$(transferred_snippets)" ]] || strict_fail 'No run snippet reached the transport.'
# Ordering: the flake check precedes the build and the root staging; the suite
# and the browser step follow the build; promotion is last. The suite's own
# remote query is one more transfer, between staging and promotion.
order="$(transferred_snippets)"
[[ "$order" == $'flake-check\nroots-stage\nsuite-query\nroots-commit' ]] ||
  strict_fail "The strict --full steps ran out of order: $(printf '%s' "$order" | tr '\n' ' ')"
suite_line="$(grep -n '^scripts --full' "$VALIDATION_TEST_LOG" | head -n1 | cut -d: -f1)"
e2e_line="$(grep -n '^e2e ' "$VALIDATION_TEST_LOG" | head -n1 | cut -d: -f1)"
[[ -n "$suite_line" && -n "$e2e_line" && "$suite_line" -lt "$e2e_line" ]] ||
  strict_fail 'The browser step must run after the registered suite.'
# The root transaction really happened on the emulated server side, and the
# release semantics are the recorded ones.
require_fixed "$VALIDATION_TEST_REMOTE_LOG" 'nix-store --add-root' \
  'Strict root staging must register the build outputs on the server.'
require_fixed "$test_root/output" 'Released prior full-validation outputs' \
  'A passing --full run without retention must release the previous outputs.'
[[ ! -e "$prior_root" && ! -L "$prior_root" ]] ||
  strict_fail 'A release must drop the previous generation of validation roots.'
[[ "$(pending_roots)" == 0 ]] ||
  strict_fail "A passing --full run left pending root staging behind: $(pending_roots)"

echo '  ✅ a passing strict --full run orders, builds, releases and reaches every step'

# Retention is the other arm of the same transaction: the new outputs are
# registered and the superseded generation is dropped.
seed_prior_root
: >"$VALIDATION_TEST_REMOTE_LOG"
strict_retain_roots=1
if ! run_strict_gate --full; then
  cat "$test_root/output" >&2
  strict_fail 'A retaining strict --full run must pass.'
fi
strict_retain_roots=0
require_fixed "$test_root/output" 'Retained the latest passing host-scoped validation outputs' \
  'VALIDATE_RETAIN_OUTPUT_ROOTS=1 must retain the new validation outputs.'
[[ -L "$strict_root_state/current/00000000000000000000000000000000-check" ]] ||
  strict_fail 'A retaining run must register the new validation output root.'
[[ ! -e "$prior_root" && ! -L "$prior_root" ]] ||
  strict_fail 'A retaining promotion must release the superseded generation it replaced.'
[[ "$(pending_roots)" == 0 ]] || strict_fail 'A retaining run left pending root staging behind.'
require_no_local_heavy 'the retaining strict --full transaction'

echo '  ✅ a retaining strict --full run promotes the new roots and releases the old ones'

# A failing suite is a late failure: the roots were already staged, so the run
# owes exactly one thing to the previous generation -- leave it untouched -- and
# exactly one thing to itself -- remove only its own pending staging.
seed_prior_root
: >"$VALIDATION_TEST_REMOTE_LOG"
export VALIDATION_TEST_SCRIPT_FAIL=1
if run_strict_gate --full; then
  unset VALIDATION_TEST_SCRIPT_FAIL
  strict_fail 'A failing registered suite must fail the strict --full transaction.'
fi
unset VALIDATION_TEST_SCRIPT_FAIL
[[ -L "$prior_root" ]] ||
  strict_fail 'A failed strict --full run must leave the previous passing roots in place.'
[[ "$(pending_roots)" == 0 ]] ||
  strict_fail "A failed strict --full run must remove only its own pending staging: $(pending_roots)"
forbid_match "$test_root/staged/transferred.log" '^roots-commit$' \
  'A failed strict --full run must never promote the roots it did not validate.'
require_match "$test_root/staged/transferred.log" '^roots-cleanup$' \
  'A failed strict --full run must clean its own staging through the transport.'
forbid_match "$VALIDATION_TEST_LOG" '^e2e ' \
  'A suite failure must stop the run before the browser step.'
require_no_local_heavy 'a failed suite in the strict --full transaction'

echo '  ✅ a failing suite keeps the previous roots and removes only its own staging'

# The browser step is the last thing before promotion, so its failure proves the
# final ordering too: everything upstream passed, and nothing was promoted.
seed_prior_root
: >"$VALIDATION_TEST_REMOTE_LOG"
export VALIDATION_TEST_E2E_STATUS=1
if run_strict_gate --full; then
  unset VALIDATION_TEST_E2E_STATUS
  strict_fail 'A failing browser step must fail the strict --full transaction.'
fi
unset VALIDATION_TEST_E2E_STATUS
require_match "$VALIDATION_TEST_LOG" '^e2e ' \
  'The failing step must be the one this case fails in.'
[[ -L "$prior_root" ]] ||
  strict_fail 'A late strict --full failure must leave the previous passing roots in place.'
[[ "$(pending_roots)" == 0 ]] || strict_fail 'A late failure left pending root staging behind.'
forbid_match "$test_root/staged/transferred.log" '^roots-commit$' \
  'A late strict --full failure must never promote the roots.'
forbid_match "$test_root/output" 'Released prior full-validation outputs' \
  'A failed strict --full run must not report a release.'
require_no_local_heavy 'a late failure in the strict --full transaction'

echo '  ✅ a late strict --full failure promotes nothing and keeps the previous roots'

# Nothing above may have touched the checkout the registered suite runs from.
[[ "$(git -C "$TESTS_REPO_ROOT" rev-parse HEAD)" == "$parent_head" &&
  "$(git -C "$TESTS_REPO_ROOT" rev-parse 'HEAD^{tree}')" == "$parent_tree" &&
  "$(git -C "$TESTS_REPO_ROOT" status --short -uno)" == "$parent_status" ]] ||
  strict_fail 'The strict --full transaction moved the parent checkout provenance.'

echo '  ✅ the local suite kept the parent checkout provenance unchanged'

echo '✅ Validation build-check selection, batching, and failure propagation passed.'
