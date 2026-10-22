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
  # The build transport and the evaluation transport share the `bash -s --`
  # shape; the staging labels are what tell them apart. A build answers with a
  # `nix build --json` manifest, an evaluation with the batched worklist, and a
  # strict snippet run (roots, the suite's boundary) with its own value.
  if [[ "$args" == *'nixhomeserver-remote-build'* ]]; then
    [[ "${VALIDATION_TEST_BUILD_FAIL:-0}" == 0 ]] || exit 42
    printf '%s\n' "$VALIDATION_TEST_BUILD_PAYLOAD"
    exit "${VALIDATION_TEST_REMOTE_BUILD_STATUS:-0}"
  fi
  if [[ "$args" == *'nixhomeserver-remote-run'* ]]; then
    printf '%s\n' "${VALIDATION_TEST_RUN_PAYLOAD:-strict-remote-snippet-value}"
    exit "${VALIDATION_TEST_RUN_STATUS:-0}"
  fi
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
            cat >"${VALIDATION_TEST_STAGED_DIR}/$(basename "$target")" ;;
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
export REMOTE_RUN=1

run_strict_gate() {
  : >"$VALIDATION_TEST_LOG"
  NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_STRICT_REPO_ROOT="$strict_repo" \
    NIXHOMESERVER_EXPECTED_HEAD="$strict_head" \
    NIXHOMESERVER_EXPECTED_TREE="$strict_tree" \
    NIXHOMESERVER_EVIDENCE_DIR="$strict_evidence" \
    NIXHOMESERVER_TEST_HOST='server' \
    VALIDATION_TEST_STRICT_TRANSPORT=1 \
    VALIDATION_TEST_STAGED_DIR="$test_root/staged" \
    VALIDATION_TEST_SUITE_OUT="$test_root/suite-eval.out" \
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

# Strict root staging only runs for a full gate, which this fixture deliberately
# does not request: the remote `remote_run` transport it uses is covered directly
# by test-strict-remote.sh, so asserting it here would only test a branch this
# run never takes.

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

echo '✅ Validation build-check selection, batching, and failure propagation passed.'
