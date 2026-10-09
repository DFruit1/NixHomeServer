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
if [[ "$args" == *' bash -s -- '* ]]; then
  cat >/dev/null
  printf '%s\n' "$VALIDATION_TEST_BATCH_PAYLOAD"
  exit "${VALIDATION_TEST_REMOTE_EVAL_STATUS:-0}"
fi
case "$args" in
  *' true'*) exit 0 ;;
  *' stage '*) cat >/dev/null; echo /tmp/nixhomeserver-remote-eval.stubarchive.a1b2c3d4.tar ;;
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
export PATH="$test_root/bin:$PATH"

run_gate
forbid_match "$VALIDATION_TEST_LOG" '^nix build' 'Lean validation must remain evaluation/script-only.'

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
forbid_match "$VALIDATION_TEST_LOG" '^nix build .*(repo-policy|hydraJobs|--full|flake check)' \
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
forbid_match "$VALIDATION_TEST_LOG" '^nix build ' \
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
  forbid_match "$VALIDATION_TEST_LOG" '^nix build ' \
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

# --- one batched worklist query ---------------------------------------------
#
# The gate used to ask `nix eval` twice on the workstation: once for
# builtins.currentSystem, once for the check names. Both must now come from a
# single batched query, and neither may still cost a local evaluation.
run_gate --build-checks
if [[ "$(grep -c ' bash -s -- ' "$VALIDATION_TEST_LOG")" != "1" ]]; then
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
forbid_match "$VALIDATION_TEST_LOG" '^ssh ' \
  'REMOTE_EVAL=0 must never open an SSH session.'
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
  forbid_match "$VALIDATION_TEST_LOG" '^nix build ' \
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
  forbid_match "$VALIDATION_TEST_LOG" '^nix build ' \
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

echo '✅ Validation build-check selection, batching, and failure propagation passed.'
