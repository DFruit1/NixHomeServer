#!/usr/bin/env bash
# Offline synthetic suite for the LWRACQ #3.3 cohesive scalar capture preparation.
#
# It is entirely local: the ssh transport double in tests/stub/ssh and the
# installed-entrypoint double in tests/stub/hermes-cli are substituted for every
# capture case, so no ssh, curl, socket, server, client, GPU node or private
# profile file is ever contacted or read. Every case asserts that both doubles
# were actually used, so a missing double fails the suite instead of reaching
# anything real.
#
# Run: bash readiness-evidence/cohesive/tests.sh
# Exit 0 with "N passed, 0 failed"; nonzero when any assertion fails.

set -uo pipefail

suite_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
runner="$suite_dir/cohesive-capture.sh"
lib="$suite_dir/cohesive-lib.sh"
availability_lib="$suite_dir/../metrics-availability-lib.sh"
stub_dir="$suite_dir/tests/stub"
fixtures="$suite_dir/tests/fixtures"
privacy_canary='PRIVATE_CONFIG_CANARY'

scratch="$(mktemp -d "${TMPDIR:-/tmp}/cohcohesive-suite.XXXXXX")" || exit 1
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
    assert_eq "$desc" "contains <$needle>" absent
  fi
}

assert_absent() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    assert_eq "$desc" absent absent
  else
    assert_eq "$desc" "without <$needle>" present
  fi
}

json_of() {
  grep -m1 "\"$1\":" | sed -e "s/^[[:space:]]*\"$1\":[[:space:]]*//" -e 's/,$//' -e 's/^"//' -e 's/"$//'
}

json_in() {
  local start="$1" end="$2" key="$3"
  printf '%s\n' "$OUT" | sed -n "/^  \"$start\": {/,/^  \"$end\": {/p" | json_of "$key"
}

stub_invocations() { wc -c <"$stub_count" | tr -d ' '; }
cli_invocations() { wc -c <"$cli_count" | tr -d ' '; }

section() { printf '\n-- %s\n' "$1"; }

reset_case() {
  case_seq=$((case_seq + 1))
  local label
  label="$(printf '%02d' "$case_seq")"
  CASE_DIR="$scratch/case-$label"
  CASE_STATE="$CASE_DIR/state"
  CASE_TMP="$CASE_DIR/tmp"
  CASE_LEDGER="$CASE_DIR/availability"
  CASE_HOME="$CASE_DIR/home"
  CASE_STDERR="$CASE_DIR/stderr"
  mkdir -p "$CASE_STATE" "$CASE_TMP" "$CASE_HOME"
  mkdir -p "$CASE_LEDGER"
  cp -R "$fixtures/availability-ledger/." "$CASE_LEDGER/"
  printf '# synthetic private profile; never read by the capture\n%s: 98304\n' "$privacy_canary" \
    >"$CASE_HOME/config.yaml"
  cp "$stub_dir/hermes-cli" "$CASE_DIR/hermes-cli"
  chmod +x "$CASE_DIR/hermes-cli"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE_DIR/launcher"
  chmod +x "$CASE_DIR/launcher"
  CASE_ENTRYPOINT="$CASE_DIR/hermes-cli"
  CASE_ENTRYPOINT_SHA="$(sha256sum "$CASE_ENTRYPOINT" | cut -d' ' -f1)"
  CASE_LAUNCHER="$CASE_DIR/launcher"
  CASE_LAUNCHER_SHA="$(sha256sum "$CASE_LAUNCHER" | cut -d' ' -f1)"
  CASE_VALIDITY=600
  CASE_CLIENT_DEADLINE=29
  CASE_SERVER_DEADLINE=29
  CASE_CLI_OUTPUT="$fixtures/client-ok.txt"
  CASE_CLI_EXIT=''
  CASE_CLI_SLEEP=''
  CASE_CLI_STDERR=''
  CASE_FRAME="$fixtures/server-ok.txt"
  CASE_SSH_EXIT=''
  CASE_BANNER=''
  CASE_STUB_STDERR=''
  CASE_SLEEP=''
  CASE_OMIT_HEADER=''
  CASE_EXTRA=''
  stub_log="$CASE_DIR/ssh.log"
  stub_count="$CASE_DIR/ssh.count"
  cli_log="$CASE_DIR/cli.log"
  cli_count="$CASE_DIR/cli.count"
  : >"$stub_log"
  : >"$stub_count"
  : >"$cli_log"
  : >"$cli_count"
  OUT=''
  RC=0
}

run_driver() {
  local subcommand="${1:-capture}"
  OUT="$(PATH="$stub_dir:$PATH" \
    COHESIVE_TEST_SEAM=1 \
    COHESIVE_SEAM_ENTRYPOINT="$CASE_ENTRYPOINT" \
    COHESIVE_SEAM_ENTRYPOINT_SHA256="$CASE_ENTRYPOINT_SHA" \
    COHESIVE_SEAM_LAUNCHER="$CASE_LAUNCHER" \
    COHESIVE_SEAM_LAUNCHER_SHA256="$CASE_LAUNCHER_SHA" \
    COHESIVE_SEAM_HERMES_HOME="$CASE_HOME" \
    COHESIVE_STATE_DIR="$CASE_STATE" \
    COHESIVE_AVAILABILITY_LEDGER="$CASE_LEDGER" \
    COHESIVE_VALIDITY_S="$CASE_VALIDITY" \
    COHESIVE_CLIENT_DEADLINE_S="$CASE_CLIENT_DEADLINE" \
    COHESIVE_SERVER_DEADLINE_S="$CASE_SERVER_DEADLINE" \
    COHESIVE_STUB_LOG="$stub_log" \
    COHESIVE_STUB_COUNT="$stub_count" \
    COHESIVE_STUB_FRAME="$CASE_FRAME" \
    COHESIVE_STUB_SSH_EXIT="$CASE_SSH_EXIT" \
    COHESIVE_STUB_BANNER="$CASE_BANNER" \
    COHESIVE_STUB_STDERR="$CASE_STUB_STDERR" \
    COHESIVE_STUB_SLEEP="$CASE_SLEEP" \
    COHESIVE_STUB_OMIT_HEADER="$CASE_OMIT_HEADER" \
    COHESIVE_STUB_EXTRA="$CASE_EXTRA" \
    COHESIVE_STUB_CLI_LOG="$cli_log" \
    COHESIVE_STUB_CLI_COUNT="$cli_count" \
    COHESIVE_STUB_CLI_OUTPUT="$CASE_CLI_OUTPUT" \
    COHESIVE_STUB_CLI_EXIT="$CASE_CLI_EXIT" \
    COHESIVE_STUB_CLI_STDERR="$CASE_CLI_STDERR" \
    COHESIVE_STUB_CLI_SLEEP="$CASE_CLI_SLEEP" \
    TMPDIR="$CASE_TMP" \
    bash "$runner" "$subcommand" 2>"$CASE_STDERR")"
  RC=$?
}

# frame_value <key> <value> / frame_without <key> / frame_append <line>
#   Derive a narrowed-frame variant from the accepted-looking fixture.
frame_value() {
  CASE_FRAME="$CASE_DIR/frame-derived.txt"
  sed -e "s|^$1=.*$|$1=$2|" "$fixtures/server-ok.txt" >"$CASE_FRAME"
}

frame_without() {
  CASE_FRAME="$CASE_DIR/frame-derived.txt"
  grep -v "^$1=" "$fixtures/server-ok.txt" >"$CASE_FRAME" || true
}

frame_append() {
  CASE_FRAME="$CASE_DIR/frame-derived.txt"
  cat "$fixtures/server-ok.txt" >"$CASE_FRAME"
  printf '%s\n' "$1" >>"$CASE_FRAME"
}

expect_bundle() {
  local desc="$1" want_rc="$2" want_status="$3" want_reason="$4"
  assert_eq "$desc: exit" "$want_rc" "$RC"
  assert_eq "$desc: status" "$want_status" "$(printf '%s\n' "$OUT" | json_of status)"
  assert_eq "$desc: reason" "$want_reason" "$(printf '%s\n' "$OUT" | json_of reason)"
}

expect_no_reads() {
  local desc="$1"
  assert_eq "$desc: zero ssh invocations" 0 "$(stub_invocations)"
  assert_eq "$desc: zero entrypoint invocations" 0 "$(cli_invocations)"
}

# --------------------------------------------------------------------------
section 'frozen contract: reuse of the accepted boundary and the D38 literals'

reuse="$(bash -c '
  source "$1" >/dev/null 2>&1 || exit 9
  source "$2" >/dev/null 2>&1 || exit 9
  printf "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" \
    "$LWRACQ_GAUGE_PROCESSING" "$COHESIVE_METRICS_ENDPOINT" "$COHESIVE_SSH_TARGET" \
    "$COHESIVE_CLIENT_LIMIT_S" "$COHESIVE_SERVER_LIMIT_S" "$COHESIVE_TOTAL_LIMIT_S" \
    "$COHESIVE_KILL_AFTER_S" "$LWRACQ_CONNECT_TIMEOUT_S" "$LWRACQ_REQUEST_TIMEOUT_S" \
    "$COHESIVE_RESIDENCY_UNIT" "$COHESIVE_GTIDLE_SAMPLES"
' _ "$availability_lib" "$lib")"
IFS='|' read -r r_gauge r_endpoint r_target r_client r_server r_total r_kill \
  r_connect r_request r_unit r_samples <<<"$reuse"
assert_eq 'cohesive bundle reuses the accepted processing gauge name' \
  'llamacpp:requests_processing' "$r_gauge"
assert_eq 'cohesive bundle reuses the accepted metrics endpoint' \
  'http://127.0.0.1:8093/metrics' "$r_endpoint"
assert_eq 'cohesive bundle reuses the accepted ssh target' 'dsaw@192.168.8.12' "$r_target"
assert_eq 'cohesive client limit is 30s' 30 "$r_client"
assert_eq 'cohesive server limit is 30s' 30 "$r_server"
assert_eq 'cohesive total limit is the sum of the two bounded operations' 60 "$r_total"
assert_eq 'kill-after is 1s' 1 "$r_kill"
assert_eq 'connect timeout reuses the accepted 3s' 3 "$r_connect"
assert_eq 'request timeout reuses the accepted 10s' 10 "$r_request"
assert_eq 'residency unit is the documented ms' 'ms' "$r_unit"
assert_eq 'two bounded gtidle samples' 2 "$r_samples"

d38="$(bash -c '
  source "$1" >/dev/null 2>&1 || exit 9
  printf "%s|%s|%s|%s|%s|%s|%s|%s" \
    "$COHESIVE_LAUNCHER" "$COHESIVE_ENTRYPOINT" "$COHESIVE_ENTRYPOINT_SHA256" \
    "$COHESIVE_LAUNCHER_SHA256" "$COHESIVE_HERMES_HOME" "$COHESIVE_GETTER_LEAF" \
    "$COHESIVE_FRAME_HEADER" "$LWRACQ_WIRE_PATTERN"
' _ "$lib")"
IFS='|' read -r d_launcher d_entry d_entry_sha d_launcher_sha d_home d_leaf d_header d_pattern <<<"$d38"
assert_eq 'D38 launcher path preserved literally' '/home/dsaw/.local/bin/hermes' "$d_launcher"
assert_eq 'D38 entrypoint path preserved literally' \
  '/home/dsaw/.hermes/hermes-agent/.hermes/bin/hermes' "$d_entry"
assert_eq 'D38 entrypoint identity hash recorded from the binding dossier' \
  '1ef34d1b50357334a5193582060431605ad66f57f7d7ec1bb08b3d310481d2a9' "$d_entry_sha"
assert_eq 'D38 launcher identity hash recorded from the binding dossier' \
  '3c3484d846fc5ac8975ab425198cdae292d9bf84da1e10be47e9bf00dcbf5fce' "$d_launcher_sha"
assert_eq 'D38 profile root preserved literally' \
  '/home/dsaw/.hermes/profiles/local-implementer' "$d_home"
assert_eq 'the getter leaf is the single selected non-secret key' \
  'model.context_length' "$d_leaf"
assert_eq 'the cohesive frame header is distinct from the availability frame' 1 \
  "$([[ "$d_header" != 'LWRACQ-METRICS-V1' ]] && echo 1 || echo 0)"
assert_eq 'the cohesive frame reuses the anchored accepted gauge pattern' 1 \
  "$([[ "$d_pattern" == ^llamacpp:* ]] && echo 1 || echo 0)"

# --------------------------------------------------------------------------
section 'wire: the frozen command strings, offline and read-only'

reset_case
run_driver wire
wire_out="$OUT"
assert_eq 'wire exits 0' 0 "$RC"
expect_no_reads 'wire'
assert_eq 'wire creates no latch' absent \
  "$([[ -e "$CASE_STATE/attempted" ]] && echo present || echo absent)"
assert_contains 'wire carries the literal D38 getter binding' \
  'HERMES_HOME=/home/dsaw/.hermes/profiles/local-implementer /home/dsaw/.hermes/hermes-agent/.hermes/bin/hermes config get model.context_length' \
  "$wire_out"
assert_contains 'wire carries the cohesive frame header' 'LWRCOHESIVE-V1' "$wire_out"
assert_contains 'wire carries the frozen metrics endpoint' \
  'http://127.0.0.1:8093/metrics' "$wire_out"
assert_contains 'wire carries the existing health endpoint' \
  'http://127.0.0.1:8093/health' "$wire_out"
assert_contains 'wire carries the props endpoint' 'http://127.0.0.1:8093/props' "$wire_out"
assert_contains 'wire carries connect timeout 3' '--connect-timeout 3' "$wire_out"
assert_contains 'wire carries request timeout 10' '--max-time 10' "$wire_out"
assert_contains 'wire carries zero curl retries' '--retry 0' "$wire_out"
assert_contains 'wire inspects all pipeline exits' 'PIPESTATUS' "$wire_out"
assert_contains 'wire reads the approved idle_status leaf' \
  '/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_status' "$wire_out"
assert_contains 'wire reads the approved idle_residency_ms leaf' \
  '/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_residency_ms' "$wire_out"
assert_contains 'wire reads only the documented per-slot props key' '"n_ctx"' "$wire_out"
assert_contains 'wire reads only the documented slots key' '"total_slots"' "$wire_out"
assert_contains 'wire discards the health body' '-o /dev/null' "$wire_out"
assert_absent 'wire grants no raw slots access' '/slots' "$wire_out"
assert_absent 'wire grants no models endpoint' '/v1/models' "$wire_out"
assert_absent 'wire grants no sudo' 'sudo' "$wire_out"
assert_absent 'wire grants no config show' 'config show' "$wire_out"
assert_absent 'wire grants no --raw form' '--raw' "$wire_out"
assert_absent 'wire grants no --json form' '--json' "$wire_out"
assert_absent 'wire grants no setter' 'config set' "$wire_out"
assert_absent 'wire grants no unsetter' 'config unset' "$wire_out"
assert_absent 'wire grants no GPU tool' 'intel_gpu_top' "$wire_out"
assert_absent 'wire grants no device enumeration' 'ls /sys' "$wire_out"
assert_absent 'wire grants no filesystem walk' 'find /' "$wire_out"
assert_absent 'wire grants no daemon or package install' 'systemctl' "$wire_out"

# --------------------------------------------------------------------------
section 'test-seam guard: production mode cannot be redirected'

reset_case
OUT="$(COHESIVE_SEAM_ENTRYPOINT="$CASE_ENTRYPOINT" \
  COHESIVE_STATE_DIR="$CASE_STATE" COHESIVE_VALIDITY_S="$CASE_VALIDITY" \
  bash "$runner" capture 2>"$CASE_STDERR")"
RC=$?
assert_eq 'an override without COHESIVE_TEST_SEAM is a usage error' 4 "$RC"
assert_contains 'the guard names the refusing variable' 'requires COHESIVE_TEST_SEAM=1' "$(cat "$CASE_STDERR")"
expect_no_reads 'seam guard'
assert_eq 'the seam guard creates no latch' absent \
  "$([[ -e "$CASE_STATE/attempted" ]] && echo present || echo absent)"

# --------------------------------------------------------------------------
section 'precondition stops: unknown state stops and spends nothing'

reset_case
CASE_VALIDITY=''
run_driver capture
expect_bundle 'no validity window' 2 HOLD freshness_unknown
assert_eq 'no validity: nothing spent' false "$(printf '%s\n' "$OUT" | json_of attempt_spent)"
assert_eq 'no validity: fact is the freshness precondition' 'precondition:freshness' \
  "$(printf '%s\n' "$OUT" | json_of fact)"
expect_no_reads 'no validity'
assert_eq 'no validity: no latch written' absent \
  "$([[ -e "$CASE_STATE/attempted" ]] && echo present || echo absent)"

reset_case
CASE_VALIDITY='soon'
run_driver capture
expect_bundle 'malformed validity window' 2 HOLD freshness_unknown
expect_no_reads 'malformed validity'

reset_case
CASE_VALIDITY='0'
run_driver capture
expect_bundle 'zero validity window' 2 HOLD freshness_unknown
expect_no_reads 'zero validity'

reset_case
CASE_ENTRYPOINT="$CASE_DIR/absent-hermes"
run_driver capture
expect_bundle 'missing entrypoint' 2 HOLD identity_unknown
assert_eq 'missing entrypoint: fact is the identity precondition' 'precondition:identity' \
  "$(printf '%s\n' "$OUT" | json_of fact)"
expect_no_reads 'missing entrypoint'

reset_case
CASE_ENTRYPOINT_SHA='0000000000000000000000000000000000000000000000000000000000000000'
run_driver capture
expect_bundle 'changed entrypoint identity' 2 HOLD identity_mismatch
expect_no_reads 'changed entrypoint identity'
assert_eq 'changed entrypoint: the on-disk hash is recorded' \
  "$(sha256sum "$CASE_ENTRYPOINT" | cut -d' ' -f1)" \
  "$(printf '%s\n' "$OUT" | json_of entrypoint_sha256_before)"
assert_eq 'changed entrypoint: the expected identity is the frozen one' "$CASE_ENTRYPOINT_SHA" \
  "$(printf '%s\n' "$OUT" | json_of entrypoint_sha256_expected)"

reset_case
CASE_LAUNCHER="$CASE_DIR/absent-launcher"
run_driver capture
expect_bundle 'missing launcher' 2 HOLD identity_unknown
expect_no_reads 'missing launcher'

reset_case
CASE_LAUNCHER_SHA='1111111111111111111111111111111111111111111111111111111111111111'
run_driver capture
expect_bundle 'changed launcher identity' 2 HOLD identity_mismatch
expect_no_reads 'changed launcher identity'

reset_case
rm -f "$CASE_HOME/config.yaml"
run_driver capture
expect_bundle 'profile root without its config' 2 HOLD identity_unknown
expect_no_reads 'profile root without its config'

reset_case
rm -rf "$CASE_LEDGER"
mkdir -p "$CASE_LEDGER"
run_driver capture
expect_bundle 'availability never established' 2 HOLD availability_not_established
assert_eq 'availability stop: fact is the availability precondition' \
  'precondition:availability' "$(printf '%s\n' "$OUT" | json_of fact)"
expect_no_reads 'availability never established'
assert_eq 'availability stop: the ledger stays absent and untouched' absent \
  "$([[ -e "$CASE_LEDGER/attempted" || -e "$CASE_LEDGER/receipt.json" ]] && echo present || echo absent)"

reset_case
printf 'attempt_id=attempt-prior\n' >"$CASE_STATE/attempted"
run_driver capture
expect_bundle 'latch already held' 3 REFUSED latch_present
expect_no_reads 'latch already held'
assert_eq 'refusal does not overwrite the held latch' 'attempt_id=attempt-prior' \
  "$(cat "$CASE_STATE/attempted")"

reset_case
printf '{"status":"CAPTURED"}\n' >"$CASE_STATE/bundle.json"
run_driver capture
expect_bundle 'bundle already held without a latch file' 3 REFUSED latch_present
expect_no_reads 'bundle already held'

reset_case
CASE_CLIENT_DEADLINE='abc'
run_driver capture
assert_eq 'malformed deadline is a usage error' 4 "$RC"
expect_no_reads 'malformed deadline'
assert_eq 'malformed deadline: nothing spent' absent \
  "$([[ -e "$CASE_STATE/attempted" ]] && echo present || echo absent)"

# --------------------------------------------------------------------------
section 'one cohesive capture: every approved fact, typed and bounded'

reset_case
CASE_EXTRA=''
run_driver capture
expect_bundle 'cohesive capture' 0 CAPTURED none
assert_eq 'capture: attempt marked spent' true "$(printf '%s\n' "$OUT" | json_of attempt_spent)"
assert_eq 'capture: exactly one entrypoint invocation' 1 "$(cli_invocations)"
assert_eq 'capture: exactly one ssh invocation' 1 "$(stub_invocations)"
assert_eq 'capture: retries are zero' 0 "$(printf '%s\n' "$OUT" | json_of retries)"
assert_eq 'capture: client value typed' 98304 "$(json_in client server value)"
assert_eq 'capture: client strength is configured intent only' 'configured_intent' \
  "$(json_in client server strength)"
assert_eq 'capture: client effective use is not established' 'not_established' \
  "$(json_in client server effective)"
assert_eq 'capture: client provenance is the selected non-secret leaf' \
  'selected_nonsecret_config_leaf' "$(json_in client server provenance)"
assert_eq 'capture: client getter exit recorded' 0 "$(json_in client server exit)"
assert_eq 'capture: server health status recorded' 200 "$(json_in server capacity health_status)"
assert_eq 'capture: per-slot capacity read from the server scalar' 98304 \
  "$(json_in server capacity props_n_ctx)"
assert_eq 'capture: total slots recorded' 2 "$(json_in server capacity props_total_slots)"
assert_eq 'capture: no aggregate was divided or inferred' false \
  "$(json_in server capacity division_or_inference_used)"
assert_eq 'capture: same-endpoint processing gauge' 1 "$(json_in server capacity requests_processing)"
assert_eq 'capture: same-endpoint deferred gauge' 0 "$(json_in server capacity requests_deferred)"
assert_eq 'capture: gtidle device reported present' 'present' \
  "$(json_in server capacity device)"
assert_eq 'capture: residency unit recorded as ms' 'ms' "$(json_in server capacity unit)"
assert_eq 'capture: all server-side exits recorded' \
  '"exits": {"gtidle_read": 0, "health_curl": 0, "props_curl": 0, "props_filter": 0, "props_map": 0, "metrics_curl": 0, "metrics_filter": 0}' \
  "$(printf '%s\n' "$OUT" | grep -m1 '"exits":' | sed -e 's/^ *//' -e 's/,$//')"
assert_eq 'capture: two gtidle samples recorded' 2 "$(printf '%s\n' "$OUT" | json_of samples)"
assert_eq 'capture: both gtidle state samples recorded verbatim' '["gt-c6", "gt-c6"]' \
  "$(json_in server capacity status)"
assert_eq 'capture: both residency samples recorded' '[987654321, 987654325]' \
  "$(json_in server capacity residency_ms)"
assert_eq 'capture: the attempt id is recorded' 1 \
  "$([[ "$(printf '%s\n' "$OUT" | json_of attempt_id)" == attempt-* ]] && echo 1 || echo 0)"
assert_eq 'capture: capacity relation compared honestly' 'equal' \
  "$(printf '%s\n' "$OUT" | json_of client_vs_per_slot_capacity)"
assert_eq 'capture: the aggregate was never divided into a client field' false \
  "$(printf '%s\n' "$OUT" | json_of aggregate_divided)"
assert_eq 'capture: availability ledger recorded as present' 'present' \
  "$(printf '%s\n' "$OUT" | json_of attempted)"
assert_eq 'capture: availability receipt hash recorded' \
  "$(sha256sum "$CASE_LEDGER/receipt.json" | cut -d' ' -f1)" \
  "$(printf '%s\n' "$OUT" | json_of receipt_sha256)"
assert_eq 'capture: the spent availability latch is unchanged' true \
  "$(printf '%s\n' "$OUT" | json_of ledger_unchanged)"
assert_eq 'capture: availability evidence is not reused as cohesive evidence' false \
  "$(printf '%s\n' "$OUT" | json_of evidence_reused)"
assert_eq 'capture: readiness is not claimed' 'not_established' \
  "$(printf '%s\n' "$OUT" | json_of readiness)"
assert_eq 'capture: idle is not claimed from a state observation' 'not_established' \
  "$(printf '%s\n' "$OUT" | json_of idle_verdict)"
assert_eq 'capture: validity window recorded' 600 "$(printf '%s\n' "$OUT" | json_of validity_s)"
assert_eq 'capture: expiry is derived from the validity window' 1 \
  "$([[ "$(printf '%s\n' "$OUT" | json_of expires_at_utc)" =~ ^20[0-9]{2}- ]] && echo 1 || echo 0)"
assert_eq 'capture: bundle hash matches the runner on disk' \
  "$(sha256sum "$runner" | cut -d' ' -f1)" "$(printf '%s\n' "$OUT" | json_of runner_sha256)"
assert_eq 'capture: bundle records the library hash on disk' \
  "$(sha256sum "$lib" | cut -d' ' -f1)" "$(printf '%s\n' "$OUT" | json_of lib_sha256)"
assert_eq 'capture: bundle persisted' present \
  "$([[ -f "$CASE_STATE/bundle.json" ]] && echo present || echo absent)"
assert_eq 'capture: latch persisted' present \
  "$([[ -f "$CASE_STATE/attempted" ]] && echo present || echo absent)"
assert_eq 'capture: private temp dirs removed' '' \
  "$(find "$CASE_TMP" -maxdepth 1 -name 'cohcohesive.*' -print -quit)"
assert_eq 'capture: the profile config was never read' absent \
  "$([[ "$OUT" == *"$privacy_canary"* || "$(cat "$CASE_STDERR")" == *"$privacy_canary"* || "$(cat "$CASE_STATE/bundle.json")" == *"$privacy_canary"* ]] && echo present || echo absent)"

cli_args="$(cat "$cli_log")"
assert_contains 'the getter received exactly the frozen verb signature' 'argc=3' "$cli_args"
assert_contains 'the getter received the config verb' 'arg=config' "$cli_args"
assert_contains 'the getter received the get subverb' 'arg=get' "$cli_args"
assert_contains 'the getter received the selected leaf' 'arg=model.context_length' "$cli_args"
assert_contains 'the getter ran under the bound profile root' "hermes_home=$CASE_HOME" "$cli_args"
wire_args="$(cat "$stub_log")"
assert_contains 'the transport received the cohesive frame header' 'LWRCOHESIVE-V1' "$wire_args"
assert_contains 'the transport received the frozen endpoint' 'http://127.0.0.1:8093/metrics' "$wire_args"
assert_contains 'the transport received zero retries' '--retry 0' "$wire_args"
assert_contains 'the transport received the approved residency leaf' \
  'gtidle/idle_residency_ms' "$wire_args"
assert_absent 'the transport received no raw slots path' '/slots' "$wire_args"

reset_case
CASE_CLI_OUTPUT="$fixtures/client-alternate-value.txt"
run_driver capture
expect_bundle 'client value not equal to the server per-slot capacity' 2 HOLD capacity_mismatch
assert_eq 'mismatch: fact is the bundle comparison' 'bundle' "$(printf '%s\n' "$OUT" | json_of fact)"
assert_eq 'mismatch: the capture was still spent once' 1 "$(cli_invocations)"
assert_eq 'mismatch: the server was still read once' 1 "$(stub_invocations)"
assert_eq 'mismatch: the relation is recorded as a mismatch' 'mismatch' \
  "$(printf '%s\n' "$OUT" | json_of client_vs_per_slot_capacity)"
assert_eq 'mismatch: no value was normalised into a positive fact' 'not_established' \
  "$(printf '%s\n' "$OUT" | json_of readiness)"

# --------------------------------------------------------------------------
section 'server frame rejection classes'

server_case() {
  local desc="$1" want_rc="$2" want_reason="$3"
  run_driver capture
  expect_bundle "$desc" "$want_rc" HOLD "$want_reason"
  assert_eq "$desc: exactly one entrypoint invocation" 1 "$(cli_invocations)"
  assert_eq "$desc: exactly one server read" 1 "$(stub_invocations)"
  assert_eq "$desc: attempt spent" true "$(printf '%s\n' "$OUT" | json_of attempt_spent)"
}

reset_case
frame_without health_status
server_case 'missing required fact' 2 missing_fact

reset_case
frame_append 'props_n_ctx=98304'
server_case 'duplicated fact' 2 duplicate_fact

reset_case
frame_append 'props_model_path=/mnt/data/qwen-27b/models/private.gguf'
server_case 'unknown key' 2 unsafe_name
assert_absent 'unknown key content is never echoed' 'private.gguf' "$OUT"

reset_case
frame_append 'llamacpp:kv_cache_usage 4'
server_case 'unknown series name' 2 unsafe_name

reset_case
frame_value props_total_slots '2.0'
server_case 'non-integral value' 2 unsafe_value

reset_case
frame_value health_status '503'
server_case 'unhealthy service' 2 health_unavailable

reset_case
frame_value gtidle_device 'absent'
server_case 'unknown device' 2 unknown_device

reset_case
frame_value gtidle_unit 'us'
server_case 'unknown unit' 2 unit_unknown

reset_case
frame_value gtidle_residency_2 '987654320'
server_case 'counter reset' 2 counter_reset

reset_case
frame_value gtidle_status_2 'gt-c0'
server_case 'idle state changed between samples' 2 idle_state_changed

reset_case
grep -v -e '^llamacpp:requests_processing ' -e '^llamacpp:requests_deferred ' \
  "$fixtures/server-ok.txt" >"$CASE_DIR/frame-no-gauge.txt"
sed -e 's|^metrics_filter_exit=.*$|metrics_filter_exit=1|' "$CASE_DIR/frame-no-gauge.txt" \
  >"$CASE_DIR/frame-no-match.txt"
CASE_FRAME="$CASE_DIR/frame-no-match.txt"
server_case 'filter matched nothing' 2 filter_no_match

reset_case
frame_value metrics_filter_exit '2'
server_case 'filter errored' 2 filter_error

reset_case
frame_value metrics_curl_exit '7'
server_case 'metrics transport failure' 2 curl_exit_nonzero

reset_case
frame_value props_curl_exit '7'
server_case 'props transport failure' 2 transport_failure

reset_case
frame_value gtidle_read_exit '1'
server_case 'device leaf read failed' 2 gtidle_read_failed

reset_case
frame_append 'LWRCOHESIVE-V1'
server_case 'a second frame' 2 unsafe_frame

reset_case
CASE_OMIT_HEADER=1
server_case 'missing frame header' 2 banner

reset_case
CASE_BANNER='REMOTE_BANNER_CANARY'
server_case 'banner before the frame' 2 banner
assert_absent 'banner content is never echoed' 'REMOTE_BANNER_CANARY' "$OUT"

reset_case
CASE_SSH_EXIT='255'
server_case 'ssh-level transport failure' 2 transport_failure
assert_eq 'ssh failure: no server facts recorded' null \
  "$(printf '%s\n' "$OUT" | json_of props_n_ctx)"

# --------------------------------------------------------------------------
section 'client frame rejection classes'

client_case() {
  local desc="$1" want_reason="$2"
  run_driver capture
  expect_bundle "$desc" 2 HOLD "$want_reason"
  assert_eq "$desc: exactly one entrypoint invocation" 1 "$(cli_invocations)"
  assert_eq "$desc: the server is never contacted" 0 "$(stub_invocations)"
  assert_eq "$desc: attempt spent" true "$(printf '%s\n' "$OUT" | json_of attempt_spent)"
}

reset_case
CASE_CLI_OUTPUT="$fixtures/client-boolean.txt"
client_case 'boolean leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-zero.txt"
client_case 'zero leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-negative.txt"
client_case 'negative leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-decimal.txt"
client_case 'decimal leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-exponent.txt"
client_case 'exponent leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-oversized.txt"
client_case 'integer beyond the bounded range' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-leading-zero.txt"
client_case 'non-canonical leading-zero leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-nonfinite.txt"
client_case 'nonfinite leaf' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-mapping.txt"
client_case 'mapping leaf' unsafe_label

reset_case
CASE_CLI_OUTPUT="$fixtures/client-keyvalue.txt"
client_case 'key=value leaf' unsafe_label

reset_case
CASE_CLI_OUTPUT="$fixtures/client-diagnostic.txt"
client_case 'raw diagnostic output' unsafe_value

reset_case
CASE_CLI_OUTPUT="$fixtures/client-empty.txt"
client_case 'empty leaf output' missing_fact

reset_case
CASE_CLI_OUTPUT="$fixtures/client-multiline.txt"
client_case 'multi-line leaf output' unsafe_frame

reset_case
CASE_CLI_OUTPUT="$fixtures/client-canary.txt"
CASE_CLI_STDERR='REMOTE_STDERR_CANARY'
client_case 'private content in the leaf output' unsafe_value
assert_absent 'client canary never reaches stdout' "$privacy_canary" "$OUT"
assert_absent 'client canary never reaches the persisted bundle' "$privacy_canary" \
  "$(cat "$CASE_STATE/bundle.json")"
assert_absent 'client stderr canary never reaches driver stderr' 'REMOTE_STDERR_CANARY' \
  "$(cat "$CASE_STDERR")"
assert_absent 'client stderr canary never reaches the persisted bundle' 'REMOTE_STDERR_CANARY' \
  "$(cat "$CASE_STATE/bundle.json")"

reset_case
CASE_CLI_EXIT='2'
client_case 'getter failed' client_getter_failed

reset_case
CASE_FRAME="$fixtures/server-json-leak.txt"
run_driver capture
expect_bundle 'leaked JSON object inside the frame' 2 HOLD unsafe_label
assert_absent 'the leaked JSON fragment is never echoed' '{"data"' "$OUT"
assert_absent 'the leaked model id is never echoed' 'qwen3.8-27b' "$OUT"
assert_eq 'leaked JSON: the server read happened exactly once' 1 "$(stub_invocations)"

reset_case
CASE_FRAME="$fixtures/server-canary.txt"
CASE_STUB_STDERR='REMOTE_STDERR_CANARY'
run_driver capture
expect_bundle 'raw body canary inside the frame' 2 HOLD unsafe_name
assert_absent 'raw-body canary never reaches stdout' 'CANARY_RAW_BODY_FRAGMENT' "$OUT"
assert_absent 'raw-body canary never reaches the persisted bundle' 'CANARY_RAW_BODY_FRAGMENT' \
  "$(cat "$CASE_STATE/bundle.json")"
assert_absent 'the leaked model path is never echoed' '/mnt/data/qwen-27b' "$OUT"
assert_absent 'remote stderr canary never reaches driver stderr' 'REMOTE_STDERR_CANARY' \
  "$(cat "$CASE_STDERR")"
assert_absent 'remote stderr canary never reaches the persisted bundle' 'REMOTE_STDERR_CANARY' \
  "$(cat "$CASE_STATE/bundle.json")"

# --------------------------------------------------------------------------
section 'frozen remote script: real narrowing from synthetic bodies (offline)'

availability_fixtures="$suite_dir/../tests/fixtures"
remote_script="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 9; cohesive_build_remote_script' _ "$lib")"
assert_eq 'the remote script is built by the frozen library' 1 \
  "$([[ "$remote_script" == *LWRCOHESIVE-V1* ]] && echo 1 || echo 0)"

# overlay_gtidle <in> <out>
#   The preparation workstation has no approved xe device node, so the frozen
#   remote script reports that read failure honestly. Replacing only the gtidle
#   lines with the approved-leaf values lets the driver's verdict on the REAL
#   extracted props/health/metrics facts be exercised end to end, offline.
overlay_gtidle() {
  sed -e 's|^gtidle_device=.*$|gtidle_device=present|' \
    -e 's|^gtidle_status_1=.*$|gtidle_status_1=gt-c6|' \
    -e 's|^gtidle_residency_1=.*$|gtidle_residency_1=987654321|' \
    -e 's|^gtidle_status_2=.*$|gtidle_status_2=gt-c6|' \
    -e 's|^gtidle_residency_2=.*$|gtidle_residency_2=987654325|' \
    -e 's|^gtidle_read_exit=.*$|gtidle_read_exit=0|' \
    "$1" >"$2"
}

local_curl_log="$scratch/local-curl.log"
local_curl_count="$scratch/local-curl.count"
local_frame_file="$scratch/local-frame.raw"
: >"$local_curl_log"
: >"$local_curl_count"
local_frame="$(PATH="$stub_dir:$PATH" \
  COHESIVE_STUB_CURL_LOG="$local_curl_log" \
  COHESIVE_STUB_CURL_COUNT="$local_curl_count" \
  COHESIVE_STUB_CURL_PROPS="$fixtures/props-body.json" \
  COHESIVE_STUB_CURL_METRICS="$availability_fixtures/raw-metrics-body.txt" \
  COHESIVE_STUB_CURL_HEALTH_CODE=200 \
  bash -c "$remote_script" 2>"$scratch/local-frame.err")"
printf '%s\n' "$local_frame" >"$local_frame_file"
assert_eq 'the offline local run used the curl double three times' 3 \
  "$(wc -c <"$local_curl_count" | tr -d ' ')"
assert_eq 'the real frame starts with the frozen header' 'LWRCOHESIVE-V1' \
  "$(printf '%s\n' "$local_frame" | head -n1)"
assert_eq 'the real narrowing extracts the documented per-slot key' 'props_n_ctx=98304' \
  "$(printf '%s\n' "$local_frame" | grep -m1 '^props_n_ctx=')"
assert_eq 'the real narrowing extracts total_slots from the same body' 'props_total_slots=2' \
  "$(printf '%s\n' "$local_frame" | grep -m1 '^props_total_slots=')"
assert_absent 'the surrounding props body never crosses the wire' 'model_path' "$local_frame"
assert_absent 'the server model path never crosses the wire' '/mnt/data' "$local_frame"
assert_absent 'the training context is not mistaken for the per-slot key' '262144' "$local_frame"
assert_absent 'the props body canary never crosses the wire' 'CANARY_PROPS_BODY_FRAGMENT' "$local_frame"
assert_eq 'the health surface is read as a status code only' 'health_status=200' \
  "$(printf '%s\n' "$local_frame" | grep -m1 '^health_status=')"
assert_eq 'the accepted anchored narrowing keeps both gauges' \
  $'llamacpp:requests_processing 0\nllamacpp:requests_deferred 3' \
  "$(printf '%s\n' "$local_frame" | grep -E '^llamacpp:requests_(processing|deferred) ')"
assert_absent 'the unfiltered metrics body never crosses the wire' 'CANARY_RAW_BODY_FRAGMENT' "$local_frame"
assert_absent 'no trailing content survives the anchored narrowing' 'trailing-canary' "$local_frame"
assert_eq 'the offline network exits are all zero' \
  'health_curl_exit=0 props_curl_exit=0 props_filter_exit=0 props_map_exit=0 metrics_curl_exit=0 metrics_filter_exit=0' \
  "$(printf '%s\n' "$local_frame" | grep -E '^(health_curl|props_curl|props_filter|props_map|metrics_curl|metrics_filter)_exit=' | tr '\n' ' ' | sed -e 's/ $//')"
if [[ -d /sys/class/drm/card0/device/tile0/gt0/gtidle ]]; then
  assert_eq 'this workstation exposes the approved device path' 'gtidle_device=present' \
    "$(printf '%s\n' "$local_frame" | grep -m1 '^gtidle_device=')"
else
  assert_eq 'a device path absent here is reported honestly, not inferred' 'gtidle_device=absent' \
    "$(printf '%s\n' "$local_frame" | grep -m1 '^gtidle_device=')"
  assert_eq 'a missing device leaf is a typed read failure, not a value' 'gtidle_read_exit=1' \
    "$(printf '%s\n' "$local_frame" | grep -m1 '^gtidle_read_exit=')"
fi

overlaid_frame="$scratch/local-frame.overlaid.txt"
overlay_gtidle "$local_frame_file" "$overlaid_frame"
# The transport double emits the frame header itself, so the fixture it replays
# is the body only: the validated frame is then byte-identical to the real one.
overlaid_body="$scratch/local-frame.overlaid.body.txt"
tail -n +2 "$overlaid_frame" >"$overlaid_body"
reset_case
CASE_FRAME="$overlaid_body"
run_driver capture
expect_bundle 'the driver accepts a frame produced by the frozen remote script' 0 CAPTURED none
assert_eq 'the real frame yields the per-slot capacity fact' 98304 \
  "$(json_in server capacity props_n_ctx)"
assert_eq 'the real frame yields the processing gauge' 0 \
  "$(json_in server capacity requests_processing)"
assert_eq 'the real frame yields the deferred gauge' 3 \
  "$(json_in server capacity requests_deferred)"

ambiguous_frame_file="$scratch/local-frame.ambiguous.raw"
: >"$local_curl_count"
PATH="$stub_dir:$PATH" \
  COHESIVE_STUB_CURL_LOG="$local_curl_log" \
  COHESIVE_STUB_CURL_COUNT="$local_curl_count" \
  COHESIVE_STUB_CURL_PROPS="$fixtures/props-body-ambiguous.json" \
  COHESIVE_STUB_CURL_METRICS="$availability_fixtures/raw-metrics-body.txt" \
  COHESIVE_STUB_CURL_HEALTH_CODE=200 \
  bash -c "$remote_script" >"$ambiguous_frame_file" 2>/dev/null
assert_eq 'an ambiguous props body yields two candidate per-slot lines' 2 \
  "$(grep -c '^props_n_ctx=' "$ambiguous_frame_file")"
assert_absent 'the ambiguous body content never crosses the wire' 'CANARY_AMBIGUOUS_BODY_FRAGMENT' \
  "$(cat "$ambiguous_frame_file")"
overlaid_ambiguous="$scratch/local-frame.ambiguous.overlaid.txt"
overlay_gtidle "$ambiguous_frame_file" "$overlaid_ambiguous"
ambiguous_body="$scratch/local-frame.ambiguous.body.txt"
tail -n +2 "$overlaid_ambiguous" >"$ambiguous_body"
reset_case
CASE_FRAME="$ambiguous_body"
run_driver capture
expect_bundle 'an ambiguous per-slot body stops instead of being guessed' 2 HOLD duplicate_fact
assert_eq 'the ambiguous stop records no per-slot value' null \
  "$(printf '%s\n' "$OUT" | json_of props_n_ctx)"

decimal_frame_file="$scratch/local-frame.decimal.raw"
: >"$local_curl_count"
PATH="$stub_dir:$PATH" \
  COHESIVE_STUB_CURL_LOG="$local_curl_log" \
  COHESIVE_STUB_CURL_COUNT="$local_curl_count" \
  COHESIVE_STUB_CURL_PROPS="$fixtures/props-body-decimal.json" \
  COHESIVE_STUB_CURL_METRICS="$availability_fixtures/raw-metrics-body.txt" \
  COHESIVE_STUB_CURL_HEALTH_CODE=200 \
  bash -c "$remote_script" >"$decimal_frame_file" 2>/dev/null
assert_eq 'a decimal or string-typed capacity is never truncated into a value' 0 \
  "$(grep -c '^props_n_ctx=' "$decimal_frame_file")"
assert_eq 'a non-canonical capacity body is reported as filter no-match' 'props_filter_exit=1' \
  "$(grep -m1 '^props_filter_exit=' "$decimal_frame_file")"
assert_absent 'the decimal body canary never crosses the wire' 'CANARY_DECIMAL_BODY_FRAGMENT' \
  "$(cat "$decimal_frame_file")"
overlaid_decimal="$scratch/local-frame.decimal.overlaid.txt"
overlay_gtidle "$decimal_frame_file" "$overlaid_decimal"
decimal_body="$scratch/local-frame.decimal.body.txt"
tail -n +2 "$overlaid_decimal" >"$decimal_body"
reset_case
CASE_FRAME="$decimal_body"
run_driver capture
expect_bundle 'a non-canonical capacity body stops at the filter' 2 HOLD filter_no_match
assert_eq 'the filter stop records no per-slot value' null \
  "$(printf '%s\n' "$OUT" | json_of props_n_ctx)"

# --------------------------------------------------------------------------
# Exponent class: a non-canonical exponent spelling must never be truncated
# into an accepted scalar. The shipped pattern and mapper are fetched from the
# library (never retyped here) and exercised directly over every spelling of the
# class, then the same class is proved end to end through the frozen remote
# script and through a full stubbed capture.

props_pattern="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 9; printf "%s" "$COHESIVE_PROPS_WIRE_PATTERN"' _ "$lib")"
props_mapper="$(bash -c 'source "$1" >/dev/null 2>&1 || exit 9; printf "%s" "$COHESIVE_PROPS_MAP_PROGRAM"' _ "$lib")"

# props_extract <synthetic props line>: exactly what the shipped narrowing emits
props_extract() {
  printf '%s' "$1" | grep -oE "$props_pattern" | sed -E -n -e "$props_mapper"
}

assert_eq 'the shipped props boundary excludes both exponent markers' 1 \
  "$([[ "$props_pattern" == *'[^0-9.eE]'* ]] && echo 1 || echo 0)"

for key in n_ctx total_slots; do
  for spelling in 2e5 2E5 2e+5 2e-5 2E+5 2E-5 25e1 05e2 1.5e3 4.5E-2 2e1.5 9e0; do
    assert_eq "the shipped narrowing emits no ${key} for the exponent spelling ${spelling}" '' \
      "$(props_extract "{\"$key\": $spelling,}")"
  done
done

assert_eq 'the shipped narrowing still extracts a canonical integer' 'props_n_ctx=98304' \
  "$(props_extract '{"n_ctx": 98304,}')"
assert_eq 'the shipped narrowing still extracts a canonical slots integer' 'props_total_slots=2' \
  "$(props_extract '{"total_slots":2,}')"
assert_eq 'the shipped narrowing tolerates whitespace around a canonical integer' 'props_n_ctx=98304' \
  "$(props_extract '{"n_ctx"  :  98304 ,}')"
assert_eq 'the shipped narrowing tolerates whitespace before the slots delimiter' 'props_total_slots=2' \
  "$(props_extract '{"total_slots" : 2 ,}')"

# props_body_frame <props-fixture> <tag>
#   Runs the frozen remote script over one synthetic /props body through the
#   offline curl double, overlays only the absent gtidle leaves (this host has
#   no approved device node) and leaves the body a stubbed capture replays in
#   PROPS_BODY_FRAME, with the raw narrowed frame in PROPS_BODY_RAW.
props_body_frame() {
  local fixture="$1" tag="$2"
  local raw="$scratch/local-frame.$tag.raw"
  local overlaid="$scratch/local-frame.$tag.overlaid.txt"
  local body="$scratch/local-frame.$tag.body.txt"
  : >"$local_curl_count"
  PATH="$stub_dir:$PATH" \
    COHESIVE_STUB_CURL_LOG="$local_curl_log" \
    COHESIVE_STUB_CURL_COUNT="$local_curl_count" \
    COHESIVE_STUB_CURL_PROPS="$fixture" \
    COHESIVE_STUB_CURL_METRICS="$availability_fixtures/raw-metrics-body.txt" \
    COHESIVE_STUB_CURL_HEALTH_CODE=200 \
    bash -c "$remote_script" >"$raw" 2>/dev/null
  overlay_gtidle "$raw" "$overlaid"
  tail -n +2 "$overlaid" >"$body"
  PROPS_BODY_RAW="$raw"
  PROPS_BODY_FRAME="$body"
}

while read -r exp_tag exp_fixture exp_canary; do
  props_body_frame "$fixtures/$exp_fixture" "$exp_tag"
  assert_eq "the frozen script emits no per-slot scalar for the $exp_tag exponent body" 0 \
    "$(grep -c '^props_n_ctx=' "$PROPS_BODY_RAW")"
  assert_eq "the frozen script emits no slots scalar for the $exp_tag exponent body" 0 \
    "$(grep -c '^props_total_slots=' "$PROPS_BODY_RAW")"
  assert_eq "the $exp_tag exponent body is reported as filter no-match" 'props_filter_exit=1' \
    "$(grep -m1 '^props_filter_exit=' "$PROPS_BODY_RAW")"
  assert_absent "the $exp_tag exponent body canary never crosses the wire" "$exp_canary" \
    "$(cat "$PROPS_BODY_RAW")"
  reset_case
  CASE_FRAME="$PROPS_BODY_FRAME"
  run_driver capture
  expect_bundle "the $exp_tag exponent body stops the full stubbed capture" 2 HOLD filter_no_match
  assert_eq "the $exp_tag exponent body records no per-slot value" null \
    "$(printf '%s\n' "$OUT" | json_of props_n_ctx)"
  assert_eq "the $exp_tag exponent body records no slots value" null \
    "$(printf '%s\n' "$OUT" | json_of props_total_slots)"
  assert_absent "the $exp_tag exponent canary never reaches stdout" "$exp_canary" "$OUT"
  assert_absent "the $exp_tag exponent canary never reaches the persisted bundle" "$exp_canary" \
    "$(cat "$CASE_STATE/bundle.json")"
done <<'EXPONENT_BODIES'
lower props-body-exponent.json CANARY_EXPONENT_BODY_FRAGMENT
upper-signed props-body-exponent-upper.json CANARY_EXPONENT_UPPER_BODY_FRAGMENT
fractional-signed props-body-exponent-fractional.json CANARY_EXPONENT_FRACTIONAL_BODY_FRAGMENT
EXPONENT_BODIES

props_body_frame "$fixtures/props-body-exponent-mixed.json" mixed
assert_eq 'a mixed body still extracts its canonical field' 'props_total_slots=2' \
  "$(grep -m1 '^props_total_slots=' "$PROPS_BODY_RAW")"
assert_eq 'a mixed body emits no scalar for the exponent-spelled field' 0 \
  "$(grep -c '^props_n_ctx=' "$PROPS_BODY_RAW")"
reset_case
CASE_FRAME="$PROPS_BODY_FRAME"
run_driver capture
expect_bundle 'a mixed body stops on the missing exponent-spelled field' 2 HOLD missing_fact
assert_eq 'the mixed stop records no per-slot value' null \
  "$(printf '%s\n' "$OUT" | json_of props_n_ctx)"
assert_eq 'the mixed stop records no slots value either' null \
  "$(printf '%s\n' "$OUT" | json_of props_total_slots)"
assert_absent 'the mixed exponent body canary never reaches stdout' \
  'CANARY_EXPONENT_MIXED_BODY_FRAGMENT' "$OUT"
assert_absent 'the mixed exponent body canary never reaches the persisted bundle' \
  'CANARY_EXPONENT_MIXED_BODY_FRAGMENT' "$(cat "$CASE_STATE/bundle.json")"

props_body_frame "$fixtures/props-body-whitespace.json" whitespace
assert_eq 'a whitespace-padded canonical body still extracts the per-slot scalar' 'props_n_ctx=98304' \
  "$(grep -m1 '^props_n_ctx=' "$PROPS_BODY_RAW")"
assert_eq 'a whitespace-padded canonical body still extracts the slots scalar' 'props_total_slots=2' \
  "$(grep -m1 '^props_total_slots=' "$PROPS_BODY_RAW")"
reset_case
CASE_FRAME="$PROPS_BODY_FRAME"
run_driver capture
expect_bundle 'the tightened boundary still captures a canonical whitespace-padded body' 0 CAPTURED none
assert_eq 'the whitespace control yields the per-slot capacity fact' 98304 \
  "$(json_in server capacity props_n_ctx)"
assert_eq 'the whitespace control yields the slots fact' 2 \
  "$(json_in server capacity props_total_slots)"
assert_eq 'the whitespace control compares equal against the client intent' 'equal' \
  "$(printf '%s\n' "$OUT" | json_of client_vs_per_slot_capacity)"
assert_absent 'the whitespace body canary never crosses the wire' 'CANARY_WHITESPACE_BODY_FRAGMENT' \
  "$(cat "$PROPS_BODY_RAW")"
assert_absent 'the whitespace body canary never reaches stdout' 'CANARY_WHITESPACE_BODY_FRAGMENT' "$OUT"

# --------------------------------------------------------------------------
section 'bounded termination: every operation is killed at its deadline'

reset_case
CASE_CLI_SLEEP=4
CASE_CLIENT_DEADLINE=1
deadline_start="$(date +%s%3N)"
run_driver capture
client_wall=$(( $(date +%s%3N) - deadline_start ))
expect_bundle 'hanging entrypoint hits its deadline' 2 HOLD deadline_exceeded
assert_eq 'client deadline: fact is the client read' 'client' "$(printf '%s\n' "$OUT" | json_of fact)"
assert_eq 'client deadline: bounded wall clock' 1 "$((client_wall < 4000 ? 1 : 0))"
assert_eq 'client deadline: the server is never contacted' 0 "$(stub_invocations)"
assert_eq 'client deadline: the single attempt is spent' true \
  "$(printf '%s\n' "$OUT" | json_of attempt_spent)"

reset_case
CASE_SLEEP=4
CASE_SERVER_DEADLINE=1
deadline_start="$(date +%s%3N)"
run_driver capture
server_wall=$(( $(date +%s%3N) - deadline_start ))
expect_bundle 'hanging server read hits its deadline' 2 HOLD deadline_exceeded
assert_eq 'server deadline: fact is the server read' 'server' "$(printf '%s\n' "$OUT" | json_of fact)"
assert_eq 'server deadline: bounded wall clock' 1 "$((server_wall < 4000 ? 1 : 0))"
assert_eq 'server deadline: the entrypoint was read once' 1 "$(cli_invocations)"
assert_eq 'server deadline: the server read happened once' 1 "$(stub_invocations)"

reset_case
CASE_CLIENT_DEADLINE=99
CASE_SERVER_DEADLINE=99
run_driver capture
expect_bundle 'oversized deadlines are clamped' 0 CAPTURED none
assert_eq 'clamped client deadline cannot exceed its limit' 29 \
  "$(printf '%s\n' "$OUT" | json_of client_deadline_s)"
assert_eq 'clamped server deadline cannot exceed its limit' 29 \
  "$(printf '%s\n' "$OUT" | json_of server_deadline_s)"

# --------------------------------------------------------------------------
section 'one-capture latch: no retry after completion, hold or interruption'

reset_case
run_driver capture
first_rc="$RC"
run_driver capture
expect_bundle 'second capture after acceptance is refused' 3 REFUSED latch_present
assert_eq 'refusal keeps the first capture' 0 "$first_rc"
assert_eq 'refusal performs no further entrypoint invocation' 1 "$(cli_invocations)"
assert_eq 'refusal performs no further server read' 1 "$(stub_invocations)"
assert_eq 'refusal does not overwrite the captured bundle' CAPTURED \
  "$(grep -m1 '"status":' "$CASE_STATE/bundle.json" | json_of status)"
assert_eq 'the refusal itself never writes a bundle' 1 \
  "$(grep -c '"schema"' "$CASE_STATE/bundle.json")"

reset_case
CASE_FRAME="$fixtures/server-canary.txt"
run_driver capture
hold_rc="$RC"
run_driver capture
expect_bundle 'second capture after a hold is refused' 3 REFUSED latch_present
assert_eq 'the hold consumed the single attempt' 2 "$hold_rc"
assert_eq 'the hold refusal performs no further server read' 1 "$(stub_invocations)"

reset_case
CASE_CLI_SLEEP=3
PATH="$stub_dir:$PATH" \
  COHESIVE_TEST_SEAM=1 \
  COHESIVE_SEAM_ENTRYPOINT="$CASE_ENTRYPOINT" \
  COHESIVE_SEAM_ENTRYPOINT_SHA256="$CASE_ENTRYPOINT_SHA" \
  COHESIVE_SEAM_LAUNCHER="$CASE_LAUNCHER" \
  COHESIVE_SEAM_LAUNCHER_SHA256="$CASE_LAUNCHER_SHA" \
  COHESIVE_SEAM_HERMES_HOME="$CASE_HOME" \
  COHESIVE_STATE_DIR="$CASE_STATE" \
  COHESIVE_AVAILABILITY_LEDGER="$CASE_LEDGER" \
  COHESIVE_VALIDITY_S="$CASE_VALIDITY" \
  COHESIVE_STUB_CLI_LOG="$cli_log" \
  COHESIVE_STUB_CLI_COUNT="$cli_count" \
  COHESIVE_STUB_CLI_OUTPUT="$CASE_CLI_OUTPUT" \
  COHESIVE_STUB_CLI_SLEEP="$CASE_CLI_SLEEP" \
  TMPDIR="$CASE_TMP" \
  bash "$runner" capture >"$CASE_DIR/signal.out" 2>"$CASE_DIR/signal.err" &
signal_pid=$!
waited=0
while [[ ! -s "$cli_count" && "$waited" -lt 80 ]]; do
  sleep 0.1
  waited=$((waited + 1))
done
kill -TERM "$signal_pid" 2>/dev/null || true
wait "$signal_pid" 2>/dev/null
interrupted_rc=$?
printf '     (interrupted driver exit: %s)\n' "$interrupted_rc"
assert_eq 'interruption: the running driver had already read the client once' 1 "$(cli_invocations)"
assert_eq 'interruption: the durable latch survives the interrupt' present \
  "$([[ -f "$CASE_STATE/attempted" ]] && echo present || echo absent)"
run_driver capture
expect_bundle 'capture after an interrupted driver is refused' 3 REFUSED latch_present
assert_eq 'interruption: no second entrypoint invocation' 1 "$(cli_invocations)"
assert_eq 'interruption: no server read is ever made' 0 "$(stub_invocations)"

# --------------------------------------------------------------------------
section 'availability latch preservation'

reset_case
ledger_before="$(find "$CASE_LEDGER" -type f | sort | xargs sha256sum)"
run_driver capture
expect_bundle 'capture with the accepted availability ledger intact' 0 CAPTURED none
ledger_after_state="$(find "$CASE_LEDGER" -type f | sort | xargs sha256sum)"
assert_eq 'the availability ledger bytes are untouched by a capture' "$ledger_before" "$ledger_after_state"
assert_eq 'the availability ledger still holds exactly its two files' 2 \
  "$(find "$CASE_LEDGER" -type f | wc -l | tr -d ' ')"
assert_eq 'the captured bundle records the before and after latch hash as equal' 1 \
  "$([[ "$(printf '%s\n' "$OUT" | json_of attempted_sha256)" == "$(printf '%s\n' "$OUT" | json_of attempted_sha256_after)" ]] && echo 1 || echo 0)"

reset_case
( sleep 1; printf '# tampered\n' >>"$CASE_LEDGER/attempted" ) &
tamper_pid=$!
CASE_CLI_SLEEP=2
run_driver capture
wait "$tamper_pid" 2>/dev/null
expect_bundle 'availability latch modified during the capture' 2 HOLD availability_latch_modified
assert_eq 'a tampered availability latch is reported unchanged=false' false \
  "$(printf '%s\n' "$OUT" | json_of ledger_unchanged)"

reset_case
( sleep 1; printf '# replaced during the capture\n' >>"$CASE_ENTRYPOINT" ) &
swap_pid=$!
CASE_CLI_SLEEP=2
run_driver capture
wait "$swap_pid" 2>/dev/null
expect_bundle 'the accepted client entry point changed during the capture' 2 HOLD identity_changed
assert_eq 'a changed entry point is reported as a different after-hash' 1 \
  "$([[ "$(printf '%s\n' "$OUT" | json_of entrypoint_sha256_after)" != "$(printf '%s\n' "$OUT" | json_of entrypoint_sha256_expected)" ]] && echo 1 || echo 0)"

# --------------------------------------------------------------------------
section 'status: offline latch and expiry state'

reset_case
run_driver status
assert_eq 'status reports a clear latch' 0 "$RC"
assert_contains 'status prints the clear latch' 'latch=clear' "$OUT"
assert_contains 'status prints the availability ledger state' 'availability_attempted=present' "$OUT"
assert_eq 'status performs no reads' 0 "$(stub_invocations)"
assert_eq 'status invokes no entrypoint' 0 "$(cli_invocations)"

reset_case
run_driver capture
run_driver status
assert_eq 'status reports a held latch' 3 "$RC"
assert_contains 'status reports the latch as held' 'latch=held' "$OUT"
assert_contains 'status reports the persisted bundle' 'bundle=present' "$OUT"
assert_contains 'status reports the bundle validity as current' 'validity=current' "$OUT"
assert_contains 'status reports the expiry timestamp' 'expires_at_utc=20' "$OUT"

reset_case
printf '{\n  "status": "CAPTURED",\n  "expires_at_utc": "2020-01-01T00:00:00Z"\n}\n' \
  >"$CASE_STATE/bundle.json"
run_driver status
assert_contains 'status reports an expired bundle as expired' 'validity=expired' "$OUT"
assert_eq 'expired bundle: the latch is still held' 3 "$RC"

# --------------------------------------------------------------------------
section 'suite integrity'

assert_eq 'the runner is executable-addressable and syntactically loadable' 0 \
  "$(bash -n "$runner" && echo 0 || echo 1)"
assert_eq 'the library is syntactically loadable' 0 \
  "$(bash -n "$lib" && echo 0 || echo 1)"
assert_eq 'the accepted availability suite is untouched and still present' present \
  "$([[ -f "$suite_dir/../tests/run-metrics-availability-tests.sh" ]] && echo present || echo absent)"
assert_eq 'the capture driver carries no absolute remote-host literal' absent \
  "$([[ "$(grep -c 'dsaw@192.168.8.12' "$runner" | tr -d ' ')" == '0' ]] && echo absent || echo present)"

# The frozen D38 identity constants are re-derived from the library (not retyped
# here) and compared against the relay files when this host carries them, so a
# stale expected hash cannot silently make every commissioned capture HOLD.
d38_identity="$(bash -c '
  source "$1" >/dev/null 2>&1 || exit 9
  printf "%s|%s|%s|%s" "$COHESIVE_ENTRYPOINT" "$COHESIVE_ENTRYPOINT_SHA256" \
    "$COHESIVE_LAUNCHER" "$COHESIVE_LAUNCHER_SHA256"
' _ "$lib")"
IFS='|' read -r d38_entry d38_entry_sha d38_launcher d38_launcher_sha <<<"$d38_identity"
for pair in "$d38_entry:$d38_entry_sha" "$d38_launcher:$d38_launcher_sha"; do
  d38_path="${pair%%:*}"
  d38_want="${pair##*:}"
  if [[ -f "$d38_path" ]]; then
    assert_eq "the frozen identity hash matches ${d38_path}" "$d38_want" \
      "$(sha256sum "$d38_path" | cut -d' ' -f1)"
  else
    printf '     (frozen identity file absent on this host: %s)\n' "$d38_path"
  fi
done

readme="$suite_dir/README.md"
assert_eq 'the handoff document ships with the preparation' present \
  "$([[ -f "$readme" ]] && echo present || echo absent)"
assert_contains 'the handoff states the separate-release boundary for the live run' \
  'must not be run until a separate' "$(cat "$readme")"
doc_reasons="$(grep -oh "COH_REASON='[a-z_]*'" "$lib" "$runner" | sed -e "s/COH_REASON='//" -e "s/'//" | sort -u)"
for reason in $doc_reasons; do
  [[ "$reason" == 'none' ]] && continue
  assert_contains "the handoff documents the ${reason} stop" "\`${reason}\`" "$(cat "$readme")"
done

printf '\n%s passed, %s failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
