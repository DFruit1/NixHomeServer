#!/usr/bin/env bash
# Offline synthetic suite for the LWRACQ metrics-availability preparation.
#
# It is entirely local: the transport is the stub in tests/stub/ssh placed
# first on PATH, so no ssh, curl, socket or server is contacted. Every case
# asserts that the stub was actually used, so a missing double fails the suite
# instead of reaching the network.
#
# Run: bash readiness-evidence/tests/run-metrics-availability-tests.sh
# Exit 0 with "N passed, 0 failed"; nonzero when any assertion fails.

set -uo pipefail

suite_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
evidence_dir="$(cd "$suite_dir/.." && pwd)"
runner="$evidence_dir/metrics-availability.sh"
lib="$evidence_dir/metrics-availability-lib.sh"
stub_dir="$suite_dir/stub"
fixtures="$suite_dir/fixtures"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/lwracq-metrics-suite.XXXXXX")" || exit 1
trap 'rm -rf -- "$scratch"' EXIT

pass=0
fail=0
case_seq=0
OUT=''
RC=0
CASE_STDERR=''

assert_eq() {
  local desc="$1" want="$2" got="$3"
  if [[ "$want" == "$got" ]]; then
    pass=$((pass + 1))
    printf 'ok   %s\n' "$desc"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n     want=[%s]\n     got =[%s]\n' "$desc" "$want" "$got"
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    assert_eq "$desc" present present
  else
    assert_eq "$desc" "contains <$needle>" "absent"
  fi
}

assert_absent() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    assert_eq "$desc" absent absent
  else
    assert_eq "$desc" "without <$needle>" "present"
  fi
}

json_of() {
  grep -m1 "\"$1\":" | sed -e 's/.*:[[:space:]]*//' -e 's/,$//' -e 's/^"//' -e 's/"$//'
}

stub_invocations() {
  wc -c <"$stub_count" | tr -d ' '
}

reset_case() {
  case_seq=$((case_seq + 1))
  local label
  label="$(printf '%02d' "$case_seq")"
  CASE_STATE="$scratch/state-$label"
  CASE_TMP="$scratch/tmp-$label"
  CASE_STDERR="$scratch/stderr-$label"
  CASE_PAYLOAD=''
  CASE_DEADLINE=29
  CASE_CURL_EXIT=0
  CASE_FILTER_EXIT=0
  CASE_SSH_EXIT=''
  CASE_BANNER=''
  CASE_STUB_STDERR=''
  CASE_OMIT=''
  CASE_SLEEP=''
  mkdir -p "$CASE_STATE" "$CASE_TMP"
  stub_log="$scratch/stub-$case_seq.log"
  stub_count="$scratch/stub-$case_seq.count"
  : >"$stub_log"
  : >"$stub_count"
  OUT=''
  RC=0
}

run_driver() {
  local subcommand="${1:-run}"
  OUT="$(PATH="$stub_dir:$PATH" \
    LWRACQ_STATE_DIR="$CASE_STATE" \
    LWRACQ_DEADLINE_S="$CASE_DEADLINE" \
    LWRACQ_STUB_LOG="$stub_log" \
    LWRACQ_STUB_COUNT="$stub_count" \
    LWRACQ_STUB_PAYLOAD="$CASE_PAYLOAD" \
    LWRACQ_STUB_CURL_EXIT="$CASE_CURL_EXIT" \
    LWRACQ_STUB_FILTER_EXIT="$CASE_FILTER_EXIT" \
    LWRACQ_STUB_SSH_EXIT="$CASE_SSH_EXIT" \
    LWRACQ_STUB_BANNER="$CASE_BANNER" \
    LWRACQ_STUB_STDERR="$CASE_STUB_STDERR" \
    LWRACQ_STUB_OMIT_STATUS="$CASE_OMIT" \
    LWRACQ_STUB_SLEEP="$CASE_SLEEP" \
    TMPDIR="$CASE_TMP" \
    bash "$runner" "$subcommand" 2>"$CASE_STDERR")"
  RC=$?
}

expect_receipt() {
  local desc="$1" want_rc="$2" want_status="$3" want_reason="$4"
  local status reason
  status="$(printf '%s\n' "$OUT" | json_of status)"
  reason="$(printf '%s\n' "$OUT" | json_of reason)"
  assert_eq "$desc: exit" "$want_rc" "$RC"
  assert_eq "$desc: status" "$want_status" "$status"
  assert_eq "$desc: reason" "$want_reason" "$reason"
}

section() {
  printf '\n-- %s\n' "$1"
}

# --------------------------------------------------------------------------
section 'frozen wire contract and constants'

consts="$(bash -c 'source "$1"; printf "%s|%s|%s|%s|%s|%s" \
  "$LWRACQ_CONNECT_TIMEOUT_S" "$LWRACQ_REQUEST_TIMEOUT_S" "$LWRACQ_CURL_RETRIES" \
  "$LWRACQ_TOTAL_LIMIT_S" "$LWRACQ_DEFAULT_DEADLINE_S" "$LWRACQ_KILL_AFTER_S"' _ "$lib")"
IFS='|' read -r c_connect c_request c_retries c_total c_deadline c_kill <<<"$consts"
assert_eq "connect timeout is 3s" 3 "$c_connect"
assert_eq "request timeout is 10s" 10 "$c_request"
assert_eq "curl retries is zero" 0 "$c_retries"
assert_eq "total limit is 30s" 30 "$c_total"
assert_eq "supervisor deadline plus kill-after stays within the total limit" 1 "$([[ $((c_deadline + c_kill)) -le $c_total ]] && echo 1 || echo 0)"

wire_pattern="$(bash -c 'source "$1"; printf "%s" "$LWRACQ_WIRE_PATTERN"' _ "$lib")"

reset_case
run_driver wire
wire_out="$OUT"
assert_eq "wire subcommand exits 0" 0 "$RC"
assert_eq "wire subcommand performs no transport call" 0 "$(stub_invocations)"
assert_contains "wire carries the frozen endpoint" 'http://127.0.0.1:8093/metrics' "$wire_out"
assert_contains "wire carries connect timeout 3" '--connect-timeout 3' "$wire_out"
assert_contains "wire carries request timeout 10" '--max-time 10' "$wire_out"
assert_contains "wire carries zero curl retries" '--retry 0' "$wire_out"
assert_contains "wire carries the frame header" 'LWRACQ-METRICS-V1' "$wire_out"
assert_contains "wire carries the frozen measurement pattern" "$wire_pattern" "$wire_out"
assert_contains "wire inspects both pipeline exits" 'PIPESTATUS' "$wire_out"
assert_absent "wire grants no /slots access" '/slots' "$wire_out"
assert_absent "wire grants no /props access" '/props' "$wire_out"
assert_absent "wire grants no sudo" 'sudo' "$wire_out"
assert_absent "wire grants no second endpoint" 'localhost' "$wire_out"

# --------------------------------------------------------------------------
section 'server-side filter privacy (frozen pattern, synthetic raw body)'

filtered="$(grep -E "$wire_pattern" "$fixtures/raw-metrics-body.txt" || true)"
assert_eq "filter keeps exactly the two canonical gauges" \
  $'llamacpp:requests_processing 0\nllamacpp:requests_deferred 3' "$filtered"
assert_absent "filter drops the raw-body canary" 'CANARY_RAW_BODY_FRAGMENT' "$filtered"
assert_absent "filter drops the second canary" 'CANARY_SECOND_LINE' "$filtered"
assert_absent "filter drops label-bearing series" 'model_name' "$filtered"
assert_absent "filter drops unrelated series" 'prompt_tokens_total' "$filtered"
assert_absent "filter drops trailing content" 'trailing-canary' "$filtered"
assert_absent "filter drops leading-whitespace lines" 'requests_processing 6' "$filtered"

# --------------------------------------------------------------------------
section 'typed acceptance'

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
run_driver run
expect_receipt 'idle zero pair' 0 ACCEPTED none
assert_eq 'accepted: processing value' 0 "$(printf '%s\n' "$OUT" | json_of requests_processing)"
assert_eq 'accepted: deferred value' 0 "$(printf '%s\n' "$OUT" | json_of requests_deferred)"
assert_eq 'accepted: curl exit recorded' 0 "$(printf '%s\n' "$OUT" | json_of curl_exit)"
assert_eq 'accepted: filter exit recorded' 0 "$(printf '%s\n' "$OUT" | json_of filter_exit)"
assert_eq 'accepted: exactly one transport call' 1 "$(stub_invocations)"
assert_eq 'accepted: receipt persisted' present "$([[ -f "$CASE_STATE/receipt.json" ]] && echo present || echo absent)"
assert_eq 'accepted: latch persisted' present "$([[ -f "$CASE_STATE/attempted" ]] && echo present || echo absent)"
assert_eq 'accepted: receipt hash matches the runner on disk' \
  "$(sha256sum "$runner" | cut -d' ' -f1)" "$(printf '%s\n' "$OUT" | json_of runner_sha256)"
wire_args="$(cat "$stub_log")"
assert_contains 'transport received the frame header' 'LWRACQ-METRICS-V1' "$wire_args"
assert_contains 'transport received the frozen endpoint' 'http://127.0.0.1:8093/metrics' "$wire_args"
assert_contains 'transport received zero retries' '--retry 0' "$wire_args"
assert_absent 'transport received no /slots path' '/slots' "$wire_args"
assert_eq 'private frame temp dir removed on exit' \
  '' "$(find "$CASE_TMP" -maxdepth 1 -name 'lwracq-metrics.*' -print -quit)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-positive.txt"
run_driver run
expect_receipt 'live-looking positive pair' 0 ACCEPTED none
assert_eq 'positive: processing value' 7 "$(printf '%s\n' "$OUT" | json_of requests_processing)"
assert_eq 'positive: deferred value' 3 "$(printf '%s\n' "$OUT" | json_of requests_deferred)"

# --------------------------------------------------------------------------
section 'typed-count rejection classes'

reset_case
CASE_PAYLOAD="$fixtures/payload-duplicate-processing.txt"
run_driver run
expect_receipt 'duplicate gauge' 2 HOLD duplicate_gauge

reset_case
CASE_PAYLOAD="$fixtures/payload-missing-deferred.txt"
run_driver run
expect_receipt 'missing gauge' 2 HOLD missing_gauge

reset_case
CASE_PAYLOAD="$fixtures/payload-negative.txt"
run_driver run
expect_receipt 'negative value' 2 HOLD unsafe_value

reset_case
CASE_PAYLOAD="$fixtures/payload-non-integral.txt"
run_driver run
expect_receipt 'non-integral value' 2 HOLD unsafe_value

reset_case
CASE_PAYLOAD="$fixtures/payload-nonfinite.txt"
run_driver run
expect_receipt 'nonfinite value' 2 HOLD unsafe_value

reset_case
CASE_PAYLOAD="$fixtures/payload-labelled.txt"
run_driver run
expect_receipt 'label-bearing series' 2 HOLD unsafe_label

reset_case
CASE_PAYLOAD="$fixtures/payload-unknown-name.txt"
run_driver run
expect_receipt 'unknown series name' 2 HOLD unsafe_name

reset_case
CASE_PAYLOAD="$fixtures/payload-trailing-junk.txt"
run_driver run
expect_receipt 'trailing content after the value' 2 HOLD unsafe_value

# --------------------------------------------------------------------------
section 'both pipeline exits and transport status'

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_CURL_EXIT=7
run_driver run
expect_receipt 'curl transport failure' 2 HOLD curl_exit_nonzero
assert_eq 'curl failure: transport was still attempted once' 1 "$(stub_invocations)"

reset_case
CASE_FILTER_EXIT=1
run_driver run
expect_receipt 'filter matched nothing' 2 HOLD filter_no_match

reset_case
CASE_FILTER_EXIT=2
run_driver run
expect_receipt 'filter errored' 2 HOLD filter_error

reset_case
CASE_SSH_EXIT=255
run_driver run
expect_receipt 'ssh-level transport failure' 2 HOLD transport_failure
assert_eq 'ssh failure: no gauge values recorded' 'null' "$(printf '%s\n' "$OUT" | json_of requests_processing)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_BANNER='REMOTE_BANNER_CANARY'
run_driver run
expect_receipt 'banner before the frame' 2 HOLD banner
assert_absent 'banner content is never echoed into the receipt' 'REMOTE_BANNER_CANARY' "$OUT"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_OMIT=curl_exit
run_driver run
expect_receipt 'incomplete transport status' 2 HOLD unsafe_frame

# --------------------------------------------------------------------------
section 'deadline'

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_SLEEP=5
CASE_DEADLINE=1
deadline_start="$(date +%s%3N)"
run_driver run
deadline_wall=$(( $(date +%s%3N) - deadline_start ))
expect_receipt 'hanging transport hits the deadline' 2 HOLD deadline_exceeded
assert_eq 'deadline: wall clock stays under the kill-after bound' 1 \
  "$((deadline_wall < 5000 ? 1 : 0))"
deadline_elapsed="$(printf '%s\n' "$OUT" | json_of elapsed_ms)"
assert_eq 'deadline: measured elapsed recorded under the total limit' 1 \
  "$([[ "$deadline_elapsed" =~ ^[0-9]+$ && "$deadline_elapsed" -le 29000 ]] && echo 1 || echo 0)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_DEADLINE=99
run_driver run
expect_receipt 'oversized deadline is clamped' 0 ACCEPTED none
assert_eq 'clamped deadline cannot exceed the 30s total' 29 \
  "$(printf '%s\n' "$OUT" | sed -n 's/.*"deadline_s": \([0-9]*\),/\1/p')"

# --------------------------------------------------------------------------
section 'one-GET latch: no retry after completion, interruption or hold'

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
run_driver run
first_rc="$RC"
run_driver run
expect_receipt 'second run after acceptance is refused' 3 REFUSED latch_present
assert_eq 'refusal keeps the first result' 0 "$first_rc"
assert_eq 'refusal performs no transport call' 1 "$(stub_invocations)"
assert_eq 'refusal does not overwrite the accepted receipt' ACCEPTED \
  "$(grep -m1 '"status":' "$CASE_STATE/receipt.json" | json_of status)"

reset_case
CASE_PAYLOAD="$fixtures/payload-labelled.txt"
run_driver run
hold_rc="$RC"
run_driver run
expect_receipt 'second run after a hold is refused' 3 REFUSED latch_present
assert_eq 'hold consumed the single request' 2 "$hold_rc"
assert_eq 'hold refusal performs no further transport call' 1 "$(stub_invocations)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_SLEEP=5
CASE_DEADLINE=1
run_driver run
interrupted_rc="$RC"
run_driver run
expect_receipt 'run after a deadline interruption is refused' 3 REFUSED latch_present
assert_eq 'interrupted run exited with a hold' 2 "$interrupted_rc"
assert_eq 'interrupted run issued exactly one transport call' 1 "$(stub_invocations)"
assert_eq 'interrupted latch is still present on disk' present \
  "$([[ -f "$CASE_STATE/attempted" ]] && echo present || echo absent)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
run_driver status
assert_eq 'status reports a clear latch with no transport call' 0 "$RC"
assert_contains 'status prints the clear latch state' 'latch=clear' "$OUT"
assert_eq 'status performs no transport call' 0 "$(stub_invocations)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_SLEEP=3
PATH="$stub_dir:$PATH" \
  LWRACQ_STATE_DIR="$CASE_STATE" \
  LWRACQ_DEADLINE_S="$CASE_DEADLINE" \
  LWRACQ_STUB_LOG="$stub_log" \
  LWRACQ_STUB_COUNT="$stub_count" \
  LWRACQ_STUB_PAYLOAD="$CASE_PAYLOAD" \
  LWRACQ_STUB_SLEEP="$CASE_SLEEP" \
  TMPDIR="$CASE_TMP" \
  bash "$runner" run >"$scratch/signal-$case_seq.out" 2>"$scratch/signal-$case_seq.err" &
signal_pid=$!
waited=0
while [[ ! -s "$stub_count" && "$waited" -lt 60 ]]; do
  sleep 0.1
  waited=$((waited + 1))
done
kill -TERM "$signal_pid" 2>/dev/null || true
wait "$signal_pid" 2>/dev/null
interrupted_rc=$?
printf '     (interrupted driver exit: %s)\n' "$interrupted_rc"
assert_eq 'interruption: the running driver had already issued its request' 1 "$(stub_invocations)"
assert_eq 'interruption: the durable latch survives the interrupt' present \
  "$([[ -f "$CASE_STATE/attempted" ]] && echo present || echo absent)"
run_driver run
expect_receipt 'run after an interrupted driver is refused' 3 REFUSED latch_present
assert_eq 'interruption: no second transport call is ever made' 1 "$(stub_invocations)"

# --------------------------------------------------------------------------
section 'privacy: rejected content is never echoed or persisted'

reset_case
CASE_PAYLOAD="$fixtures/payload-private-canary.txt"
CASE_STUB_STDERR='REMOTE_STDERR_CANARY'
run_driver run
expect_receipt 'unsafe series inside a frame' 2 HOLD unsafe_name
assert_absent 'raw-body canary never reaches stdout' 'CANARY_RAW_BODY_FRAGMENT' "$OUT"
assert_absent 'stderr canary never reaches driver stderr' 'REMOTE_STDERR_CANARY' "$(cat "$CASE_STDERR")"
assert_absent 'raw-body canary never reaches the persisted receipt' 'CANARY_RAW_BODY_FRAGMENT' "$(cat "$CASE_STATE/receipt.json")"
assert_absent 'stderr canary never reaches the persisted receipt' 'REMOTE_STDERR_CANARY' "$(cat "$CASE_STATE/receipt.json")"
assert_eq 'no private frame temp dir survives' '' \
  "$(find "$CASE_TMP" -maxdepth 1 -name 'lwracq-metrics.*' -print -quit)"

reset_case
CASE_PAYLOAD="$fixtures/payload-ok-zero.txt"
CASE_BANNER='REMOTE_BANNER_CANARY'
CASE_STUB_STDERR='REMOTE_STDERR_CANARY'
run_driver run
expect_receipt 'banner canary outside the frame' 2 HOLD banner
assert_absent 'banner canary never reaches stdout' 'REMOTE_BANNER_CANARY' "$OUT"
assert_absent 'banner canary never reaches driver stderr' 'REMOTE_BANNER_CANARY' "$(cat "$CASE_STDERR")"
assert_absent 'banner canary never reaches the persisted receipt' 'REMOTE_BANNER_CANARY' "$(cat "$CASE_STATE/receipt.json")"
assert_absent 'stderr canary never reaches the persisted receipt' 'REMOTE_STDERR_CANARY' "$(cat "$CASE_STATE/receipt.json")"

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
