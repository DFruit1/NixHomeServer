#!/usr/bin/env bash
# Regression test for scripts/helpers/remote-eval.sh.
#
# The helper decides where a NixOS configuration evaluation physically runs, so a
# silent mistake here either slows the whole suite down or, worse, makes a
# transport failure look like a passing assertion. These checks pin the parts
# that are cheap to verify without touching the server.
#
# Everything network-facing is exercised through REMOTE_EVAL=0 so the test is
# hermetic; the remote transport itself is covered by the offline fallback tests
# below, which use an unroutable host and assert we fail closed.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/remote-eval.sh"

fail() {
  echo "❌ $1" >&2
  exit 1
}

mock_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-eval-mock.XXXXXX")"
trap 'rm -rf "$mock_dir"' EXIT
export REMOTE_EVAL_TEST_LOG="$mock_dir/nix.log"
export REAL_TAR="$(command -v tar)"
export REAL_RM="$(command -v rm)"
cat >"$mock_dir/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >>"$REMOTE_EVAL_TEST_LOG"
printf '{"hostId":"deadbeef","linux":true}\n'
EOF
cat >"$mock_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\\n' "$*" >>"$REMOTE_EVAL_TEST_LOG"
echo 'synthetic transport unavailable' >&2
exit 255
EOF
chmod +x "$mock_dir/nix" "$mock_dir/ssh"
PATH="$mock_dir:$PATH"

echo "▶ remote-eval helper contract"

# --- argument validation -----------------------------------------------------

if remote_eval_batch_json >/dev/null 2>&1; then
  fail "remote_eval_batch_json accepted an empty query list"
fi

if remote_eval_batch_json 'no-equals-sign' >/dev/null 2>&1; then
  fail "remote_eval_batch_json accepted a query with no '=' separator"
fi

if remote_eval_batch_json 'not-an-identifier=f.nixosConfigurations' >/dev/null 2>&1; then
  fail "remote_eval_batch_json accepted a non-identifier query name"
fi

echo "  ✅ rejects empty, malformed, and non-identifier queries"

# --- the generated Nix expression is well-formed -----------------------------
#
# Batch the cheapest possible query and assert the JSON object shape. REMOTE_EVAL=0
# keeps this local; the point is the wrapper's expression assembly, not speed.
batch_json="$(REMOTE_EVAL=0 remote_eval_batch_json \
  'hostId=f.nixosConfigurations.server.config.networking.hostId' \
  'linux=f.nixosConfigurations.server.config.nixpkgs.hostPlatform.isLinux' 2>/dev/null)" \
  || fail "local batch evaluation failed"

jq -e '.hostId | test("^[0-9a-fA-F]{8}$")' <<<"$batch_json" >/dev/null \
  || fail "batched hostId did not survive the wrapper: ${batch_json}"
jq -e '.linux == true' <<<"$batch_json" >/dev/null \
  || fail "batched boolean did not survive the wrapper: ${batch_json}"

# A single query must still produce a JSON object, never a bare scalar, so that
# callers can always index by name.
jq -e 'type == "object"' <<<"$batch_json" >/dev/null \
  || fail "batch output is not a JSON object"

echo "  ✅ batches multiple queries into one JSON object"

# --- fail closed on an unreachable target ------------------------------------
#
# The contract is not "return non-zero": a server outage must never fail the
# suite. It is "never let a transport problem masquerade as a result". So an
# unroutable host must (a) warn on stderr, (b) record a reason, and (c) still
# return the correct value from the local fallback. If it ever returned non-zero
# here, every test on the box would break whenever the server rebooted.
stderr_file="$(mktemp)"
fallback_json="$(
  REMOTE_EVAL=1 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId' \
    2>"$stderr_file"
)" || { rm -f "$stderr_file"; fail "local fallback did not produce a value after an unreachable target"; }

jq -e '.hostId | test("^[0-9a-fA-F]{8}$")' <<<"$fallback_json" >/dev/null \
  || { rm -f "$stderr_file"; fail "fallback value is malformed: ${fallback_json}"; }

grep -q "falling back to local evaluation" "$stderr_file" \
  || { rm -f "$stderr_file"; fail "an unreachable target did not warn that it fell back"; }

# The reason must reach the operator, not just an internal variable: a silent
# fallback would let the suite quietly do the slow thing on the workstation with
# nobody noticing why.
grep -q "is not reachable with BatchMode" "$stderr_file" \
  || { rm -f "$stderr_file"; fail "the fallback warning did not name the cause: $(cat "$stderr_file")"; }

rm -f "$stderr_file"

echo "  ✅ warns, records a reason, and still returns the value when the target is unreachable"

# --- opt-out is honoured ------------------------------------------------------
#
# REMOTE_EVAL=0 must never attempt the network. Point it at a blackhole and
# confirm it completes quickly rather than waiting on a connect timeout.
opt_out_start=$SECONDS
REMOTE_EVAL=0 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
  remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId' \
  >/dev/null 2>&1 || fail "REMOTE_EVAL=0 evaluation failed"
opt_out_elapsed=$(( SECONDS - opt_out_start ))

if ((opt_out_elapsed > 20)); then
  fail "REMOTE_EVAL=0 appears to have attempted the network (${opt_out_elapsed}s)"
fi

echo "  ✅ REMOTE_EVAL=0 stays local"

# --- strict mode refuses missing identity before any local fallback ----------
# Strict mode is a separate contract from the ordinary fallback behavior.
strict_stderr="$(mktemp)"
if REMOTE_EVAL=1 REMOTE_EVAL_HOST="dsaw@192.0.2.1" \
    NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD="" NIXHOMESERVER_EXPECTED_TREE="" \
    NIXHOMESERVER_EVIDENCE_DIR="" \
    remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId' \
    >/dev/null 2>"$strict_stderr"; then
  rm -f "$strict_stderr"
  fail "strict evaluation accepted missing source identity/evidence inputs"
fi
rm -f "$strict_stderr"

echo "  ✅ strict mode rejects missing identity before fallback"

if REMOTE_EVAL=0 NIXHOMESERVER_REQUIRE_REMOTE=1 \
    remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId' \
    >/dev/null 2>"$strict_stderr"; then
  rm -f "$strict_stderr"
  fail "strict evaluation accepted REMOTE_EVAL=0"
fi
if ! grep -q 'conflicts with REMOTE_EVAL=0' "$strict_stderr"; then
  rm -f "$strict_stderr"
  fail "strict/opt-out conflict was not diagnosed before evaluation"
fi
rm -f "$strict_stderr"

echo "  ✅ strict mode rejects the local opt-out before evaluation"

# Full transport boundary: an isolated committed tree and fail-closed synthetic
# SSH/Nix endpoints exercise the real strict helper without a server or Nix.
fixture_repo="$mock_dir/source"
remote_root="$mock_dir/remote"
mkdir -p "$fixture_repo/scripts/helpers" "$remote_root"
cp "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh" \
  "$TESTS_REPO_ROOT/scripts/helpers/remote-eval.sh" \
  "$TESTS_REPO_ROOT/scripts/helpers/deploy-archive-cleanup.sh" \
  "$fixture_repo/scripts/helpers/"
printf 'fixture source\n' >"$fixture_repo/tracked.txt"
git -C "$fixture_repo" init -q
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid add .
git -C "$fixture_repo" -c user.name=test -c user.email=test@example.invalid commit -qm fixture
fixture_head="$(git -C "$fixture_repo" rev-parse HEAD)"
fixture_tree="$(git -C "$fixture_repo" rev-parse 'HEAD^{tree}')"
cat >"$mock_dir/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix ref=%s args=%s\n' "${NIXHOMESERVER_FLAKE_REF_FOR_EVAL:-unset}" "$*" >>"$REMOTE_EVAL_TEST_LOG"
if [[ "${1:-}" != eval ]]; then
  printf 'FORBIDDEN nix %s\n' "$*" >>"$REMOTE_EVAL_TEST_LOG"
  exit 97
fi
case "${FAKE_NIX_MODE:-success}" in
  target) echo '{"localAdminUser":"fixture","serverLanIP":"127.0.0.1","hostId":"deadbeef"}' ;;
  success) echo '{"hostId":"deadbeef"}' ;;
  empty) : ;;
  malformed) echo 'not-json' ;;
  failure) exit 42 ;;
  source-mutate)
    echo '{"hostId":"deadbeef"}'
    printf 'mutated\n' >"$FIXTURE_REPO/tracked.txt"
    ;;
  *) exit 90 ;;
esac
EOF
cat >"$mock_dir/ssh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while (($#)); do
  case "$1" in -o) shift 2 ;; -T) shift ;; -*) shift ;; *) break ;; esac
done
host="$1"; shift
printf 'ssh host=%s args=%s\n' "$host" "$*" >>"$REMOTE_EVAL_TEST_LOG"
[[ "$host" == fake-server || "$host" == fixture@127.0.0.1 ]] || exit 91
case "${SSH_MODE:-success}" in
  transport255) exit 255 ;;
  transport42) exit 42 ;;
esac
if [[ "${1:-}" == true ]]; then exit 0; fi
if [[ "${1:-}" == hostname ]]; then echo 'fixture.example.invalid'; exit 0; fi
if [[ "${1:-}" == uname ]]; then echo 'Linux fixture 1.0 x86_64'; exit 0; fi
if [[ $# == 1 && "$1" == "mktemp -d /tmp/nixhomeserver-remote-eval."* ]]; then
  dir="$(mktemp -d "$FAKE_REMOTE_ROOT/run.XXXXXX")"
  echo "$dir"; exit 0
fi
if [[ $# == 1 && "$1" == cat* ]]; then
  path="${1#cat > }"
  exec cat >"$path"
fi
if [[ "${1:-}" == bash ]]; then
  shift
  if [[ "${SSH_TRACE:-0}" == 1 ]]; then
    exec 9>>"$REMOTE_EVAL_TEST_LOG"
    BASH_XTRACEFD=9 bash -x "$@"
  else
    exec bash "$@"
  fi
  exit $?
fi
if [[ $# == 1 ]]; then exec bash -c "$1"; fi
exit 92
EOF
cat >"$mock_dir/tar" <<'EOF'
#!/usr/bin/env bash
"$REAL_TAR" "$@" || exit $?
is_extract=false
for arg in "$@"; do [[ "$arg" == -xf ]] && is_extract=true; done
if [[ "${MANIFEST_MODE:-}" == mutate && "$is_extract" == true ]]; then
  while (($#)); do
    if [[ "$1" == -C ]]; then
      root="$2"
      printf 'manifest mutation\n' >>"$root/scripts/helpers/remote-eval.sh"
      break
    fi
    shift
  done
fi
EOF
cat >"$mock_dir/rm" <<'EOF'
#!/usr/bin/env bash
if [[ "${CLEANUP_MODE:-}" == fail ]]; then
  for arg in "$@"; do
    case "$arg" in "$FAKE_REMOTE_ROOT"/run.*|"$FAKE_REMOTE_ROOT"/archive.tar) exit 1 ;; esac
  done
fi
exec "$REAL_RM" "$@"
EOF
for command_name in cargo chromium chromium-browser google-chrome playwright npm pnpm; do
  cat >"$mock_dir/$command_name" <<'EOF'
#!/usr/bin/env bash
printf 'FORBIDDEN %s %s\n' "${0##*/}" "$*" >>"$REMOTE_EVAL_TEST_LOG"
exit 97
EOF
  chmod +x "$mock_dir/$command_name"
done
chmod +x "$mock_dir/nix" "$mock_dir/ssh" "$mock_dir/tar" "$mock_dir/rm"
source "$fixture_repo/scripts/helpers/repo-common.sh"
source "$fixture_repo/scripts/helpers/remote-eval.sh"
remote_eval_host=fake-server
remote_stage="$remote_root/archive.tar"
stage_archive_on_remote() {
  if [[ "${ARCHIVE_MODE:-success}" == transfer-fail ]]; then return 1; fi
  cp "$1" "$remote_stage"
  if [[ "${ARCHIVE_MODE:-success}" == mismatch ]]; then printf 'corrupt' >>"$remote_stage"; fi
  echo "$remote_stage"
}
strict_call() {
  (cd "$fixture_repo" && PATH="$mock_dir:$PATH" FAKE_REMOTE_ROOT="$remote_root" \
    FIXTURE_REPO="$fixture_repo" REMOTE_EVAL_TEST_LOG="$REMOTE_EVAL_TEST_LOG" HERMES_KANBAN_TASK=t_fixture \
    HERMES_KANBAN_BOARD=fixture HERMES_KANBAN_RUN_ID=r_fixture \
    NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD="${EXPECTED_HEAD_OVERRIDE:-$fixture_head}" \
    NIXHOMESERVER_EXPECTED_TREE="${EXPECTED_TREE_OVERRIDE:-$fixture_tree}" \
    NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId')
}
assert_no_forbidden_local_tools() {
  if grep -q '^FORBIDDEN ' "$REMOTE_EVAL_TEST_LOG"; then
    fail "strict evaluation attempted a local heavy/build/browser/cargo command"
  fi
}
: >"$REMOTE_EVAL_TEST_LOG"
strict_output="$(strict_call)" || { cat "$REMOTE_EVAL_TEST_LOG" >&2; fail "synthetic strict remote evaluation failed"; }
jq -e '.hostId == "deadbeef"' <<<"$strict_output" >/dev/null || fail "strict remote output was lost"
strict_receipt=("$fixture_repo"/.tmp/evidence/eval-*.receipt.json)
[[ -f "${strict_receipt[0]}" ]] || fail "strict evaluation did not write its receipt"
jq -e '.task == "t_fixture" and .board == "fixture" and .run == "r_fixture" and .exit_status == 0 and .cleanup == "success" and .actual_host == "fixture.example.invalid" and .actual_system == "Linux fixture 1.0 x86_64"' "${strict_receipt[0]}" >/dev/null || fail "strict receipt omitted boundary evidence"

: >"$REMOTE_EVAL_TEST_LOG"
remote_eval_host=""
target_output="$(FAKE_NIX_MODE=target strict_call)" || fail "configured strict target did not resolve"
remote_eval_host=fake-server
jq -e '.hostId == "deadbeef"' <<<"$target_output" >/dev/null || fail "target resolution changed evaluator output"
grep -q 'host=fixture@127.0.0.1' "$REMOTE_EVAL_TEST_LOG" || fail "strict route ignored configured target"
assert_no_forbidden_local_tools
echo "  ✅ configured target resolution"

for identity_case in head tree; do
  : >"$REMOTE_EVAL_TEST_LOG"
  if [[ "$identity_case" == head ]]; then
    if EXPECTED_HEAD_OVERRIDE=0000000000000000000000000000000000000000 strict_call >/dev/null 2>&1; then
      fail "strict evaluation accepted a mismatched commit"
    fi
  else
    if EXPECTED_TREE_OVERRIDE=0000000000000000000000000000000000000000 strict_call >/dev/null 2>&1; then
      fail "strict evaluation accepted a mismatched tree"
    fi
  fi
  [[ ! -s "$REMOTE_EVAL_TEST_LOG" ]] || fail "identity mismatch reached fake evaluator"
  assert_no_forbidden_local_tools
done
echo "  ✅ commit/tree mismatch rejected before remote evaluation"

# Tracing must not divert remote stderr markers from the strict classifier.
: >"$REMOTE_EVAL_TEST_LOG"
traced_output="$(SSH_TRACE=1 strict_call)" || fail "traced strict evaluation failed"
jq -e '.hostId == "deadbeef"' <<<"$traced_output" >/dev/null || fail "tracing changed strict output"
traced_receipt=("$fixture_repo"/.tmp/evidence/eval-*.receipt.json)
jq -e '.exit_status == 0 and .cleanup == "success"' "${traced_receipt[0]}" >/dev/null || fail "tracing diverted the cleanup marker"
grep -q '^+ ' "$REMOTE_EVAL_TEST_LOG" || fail "SSH_TRACE did not capture xtrace"
assert_no_forbidden_local_tools
if [[ -n "${REMOTE_EVAL_TRACE_ARCHIVE:-}" ]]; then
  cp "$REMOTE_EVAL_TEST_LOG" "$REMOTE_EVAL_TRACE_ARCHIVE"
fi
echo "  ✅ SSH_TRACE preserves cleanup-marker classification"

# Strict transport, evaluator and payload failures must never invoke local Nix.
for scenario in transport255 transport42 failure empty malformed; do
  : >"$REMOTE_EVAL_TEST_LOG"
  if (cd "$fixture_repo" && PATH="$mock_dir:$PATH" FAKE_REMOTE_ROOT="$remote_root" \
      SSH_MODE="$scenario" FAKE_NIX_MODE="$scenario" \
      NIXHOMESERVER_REQUIRE_REMOTE=1 NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" \
      NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
      NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
      remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId') \
      >/dev/null 2>&1; then fail "strict $scenario unexpectedly succeeded"; fi
  if grep -Fq 'ref=git+file://' "$REMOTE_EVAL_TEST_LOG"; then
    fail "strict $scenario invoked local evaluation fallback"
  fi
  assert_no_forbidden_local_tools
done
echo "  ✅ strict remote 255/42, evaluator nonzero, empty and malformed payload fail closed"

# Staging failures and extracted-tree mismatches fail closed before local fallback.
: >"$REMOTE_EVAL_TEST_LOG"
if ARCHIVE_MODE=transfer-fail strict_call >/dev/null 2>&1; then fail "strict evaluation accepted a transfer failure"; fi
if grep -q '^nix ' "$REMOTE_EVAL_TEST_LOG"; then fail "transfer failure reached the evaluator"; fi
assert_no_forbidden_local_tools
: >"$REMOTE_EVAL_TEST_LOG"
if MANIFEST_MODE=mutate strict_call >/dev/null 2>&1; then fail "strict evaluation accepted a manifest mismatch"; fi
if grep -Fq 'ref=git+file://' "$REMOTE_EVAL_TEST_LOG"; then
  fail "manifest mismatch invoked local evaluation fallback"
fi
assert_no_forbidden_local_tools

echo "  ✅ transfer failure and extracted manifest mismatch fail closed"

# A source change during remote work invalidates the strict result.
: >"$REMOTE_EVAL_TEST_LOG"
if FAKE_NIX_MODE=source-mutate strict_call >/dev/null 2>&1; then
  fail "strict evaluation accepted a source mutation"
fi
printf 'fixture source\n' >"$fixture_repo/tracked.txt"
if grep -Fq 'ref=git+file://' "$REMOTE_EVAL_TEST_LOG"; then
  fail "source mutation invoked local evaluation fallback"
fi
assert_no_forbidden_local_tools
echo "  ✅ source mutation after remote evaluation is rejected"

: >"$REMOTE_EVAL_TEST_LOG"
prior_receipts=("$fixture_repo"/.tmp/evidence/eval-*.receipt.json)
cleanup_output=""
if cleanup_output="$(CLEANUP_MODE=fail strict_call 2>&1)"; then
  fail "strict evaluation accepted remote cleanup failure"
fi
cleanup_receipts=("$fixture_repo"/.tmp/evidence/eval-*.receipt.json)
cleanup_receipt=""
for candidate in "${cleanup_receipts[@]}"; do
  already_present=false
  for prior in "${prior_receipts[@]}"; do
    [[ "$candidate" == "$prior" ]] && already_present=true
  done
  if [[ "$already_present" == false ]]; then cleanup_receipt="$candidate"; fi
done
[[ -n "$cleanup_receipt" ]] || { printf '%s\n' "$cleanup_output" >&2; fail "cleanup failure receipt was not created"; }
jq -e '.cleanup == "failed" and .exit_status != 0' "$cleanup_receipt" >/dev/null || {
  jq '{exit_status,cleanup,stderr}' "$cleanup_receipt" >&2
  fail "cleanup failure was not recorded"
}
if grep -Fq 'ref=git+file://' "$REMOTE_EVAL_TEST_LOG"; then
  fail "cleanup failure invoked local evaluation fallback"
fi
assert_no_forbidden_local_tools
"$REAL_RM" -rf "$remote_root"/run.* "$remote_stage"
echo "  ✅ cleanup failure receipt and strict refusal verified"

# A mismatched uploaded archive is rejected before the remote script executes.
: >"$REMOTE_EVAL_TEST_LOG"
if (cd "$fixture_repo" && PATH="$mock_dir:$PATH" FAKE_REMOTE_ROOT="$remote_root" \
    ARCHIVE_MODE=mismatch NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD="$fixture_head" NIXHOMESERVER_EXPECTED_TREE="$fixture_tree" \
    NIXHOMESERVER_EVIDENCE_DIR="$fixture_repo/.tmp/evidence" \
    remote_eval_batch_json 'hostId=f.nixosConfigurations.server.config.networking.hostId') \
    >/dev/null 2>&1; then fail "strict evaluation accepted a mismatched archive"; fi
if grep -Fq 'ref=git+file://' "$REMOTE_EVAL_TEST_LOG"; then
  fail "archive mismatch invoked local evaluation fallback"
fi
assert_no_forbidden_local_tools
echo "  ✅ uploaded archive digest mismatch rejected before evaluation"

echo "✅ remote-eval helper regression test passed"
