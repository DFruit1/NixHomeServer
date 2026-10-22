#!/usr/bin/env bash
# LWRACQ-20261014-v2 #3.3 cohesive scalar capture driver (finding CI-LWR-001).
#
# ONE future cohesive privacy-safe readiness capture, prepared offline. It reads
# only the existing surfaces the reviewer and coordinator already allowed:
#   1. the D38 body-free single-leaf client getter (config get model.context_length
#      under the exact installed wrapper + HERMES_HOME binding),
#   2. the server's own scalar /props per-slot field with total_slots,
#   3. the same-endpoint processing/deferred gauges through the accepted anchored
#      narrowing,
#   4. the existing /health numeric status,
#   5. the two bounded unprivileged xe gtidle leaves.
#
# It performs no server transaction, no activation, no install/reload, no
# inference, no D17 reservation, no /slots read, no GPU tool, no sudo, no
# enumeration and no private-file read. It never writes to, clears or reuses the
# accepted availability ledger; it only checks that the spent availability latch
# is present and that its bytes are unchanged across the capture.
#
# The one-capture latch is written durably BEFORE the first read and is never
# removed by this runner: any later invocation refuses with zero reads, so an
# interrupted, killed, timed-out or held capture cannot be retried.
#
# Offline preparation only: until the independent verifier explicitly ACCEPTs
# this exact preparation, 'capture' must not be executed. 'wire' and 'status'
# are read-only local operations and never contact the server or the client.
#
# Usage:
#   cohesive-capture.sh capture   # the single cohesive capture (only after ACCEPT)
#   cohesive-capture.sh wire      # print both frozen command strings; no read
#   cohesive-capture.sh status    # print the durable latch/bundle state; no read
#
# Environment:
#   COHESIVE_STATE_DIR         durable latch/bundle dir (default:
#                              "${HERMES_KANBAN_WORKSPACE:-<repo>}/readiness-evidence/cohesive/live")
#   COHESIVE_AVAILABILITY_LEDGER  accepted availability ledger dir (default:
#                              "${LWRACQ_STATE_DIR:-...}/readiness-evidence/live")
#   COHESIVE_VALIDITY_S        whole-second validity window for the bundle; it
#                              has NO default, because no approved window value
#                              exists in the binding plans and an unknown
#                              freshness must stop rather than be inferred
#   COHESIVE_CLIENT_DEADLINE_S / COHESIVE_SERVER_DEADLINE_S
#                              supervisor deadlines; clamped so neither can
#                              exceed its 30s limit including kill-after
#   COHESIVE_TEST_SEAM=1       required for any COHESIVE_SEAM_* override; without
#                              it the frozen D38 identity is always used
#
# Exit codes: 0 CAPTURED, 2 HOLD (typed reason), 3 REFUSED (latch held, no read),
#             4 usage or local configuration error.

set -u
set -o pipefail

coh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=readiness-evidence/cohesive/cohesive-lib.sh
source "$coh_script_dir/cohesive-lib.sh"

coh_repo_root="$(cd "$coh_script_dir/../.." && pwd)"

COH_STATUS='HOLD'
COH_REASON='none'
COH_FACT=''
COH_ATTEMPT_SPENT=0
COH_ATTEMPT_ID=''
COH_START_UTC=''
COH_END_UTC=''
COH_VALIDITY_S=''
COH_EXPIRES_UTC=''
COH_IDENTITY_MODE='frozen_default'
COH_ENTRYPOINT_RESOLVED=''
COH_ENTRYPOINT_SHA_EXPECTED=''
COH_ENTRYPOINT_SHA_BEFORE=''
COH_ENTRYPOINT_SHA_AFTER=''
COH_LAUNCHER_RESOLVED=''
COH_LAUNCHER_SHA=''
COH_LAUNCHER_SHA_EXPECTED=''
COH_HOME_RESOLVED=''
COH_HOME_CONFIG=''
COH_CLIENT_EXIT=''
COH_CLIENT_VALUE=''
COH_CLIENT_ELAPSED_MS=''
COH_SERVER_EXIT=''
COH_SERVER_ELAPSED_MS=''
COH_CLIENT_DEADLINE_S=''
COH_SERVER_DEADLINE_S=''
COH_AVAIL_LEDGER=''
COH_AVAIL_ATTEMPTED_SHA=''
COH_AVAIL_ATTEMPTED_SHA_AFTER=''
COH_AVAIL_RECEIPT_SHA=''
COH_AVAIL_UNCHANGED=''
COH_GTIDLE_DEVICE=''
COH_GTIDLE_UNIT=''
COH_GTIDLE_STATUS_1=''
COH_GTIDLE_RESIDENCY_1=''
COH_GTIDLE_STATUS_2=''
COH_GTIDLE_RESIDENCY_2=''
COH_GTIDLE_READ_EXIT=''
COH_HEALTH_STATUS=''
COH_HEALTH_CURL_EXIT=''
COH_PROPS_NCTX=''
COH_PROPS_SLOTS=''
COH_PROPS_CURL_EXIT=''
COH_PROPS_FILTER_EXIT=''
COH_PROPS_MAP_EXIT=''
COH_METRICS_CURL_EXIT=''
COH_METRICS_FILTER_EXIT=''
COH_PROC=''
COH_DEFER=''
COH_CAPACITY_RELATION=''
COH_STATE_DIR=''
COH_TMPDIR=''
COH_RUNNER_SHA=''
COH_LIB_SHA=''

usage() {
  cat <<'EOF'
Usage: cohesive-capture.sh [capture|wire|status]

  capture  Perform the single bounded cohesive scalar capture. Only valid after
           the independent verifier explicitly ACCEPTs this preparation.
  wire     Print both frozen command strings (offline; never contacts anything).
  status   Print the durable latch/bundle state (offline; never contacts).
EOF
}

die() {
  printf 'cohesive-capture: %s\n' "$1" >&2
  exit 4
}

coh_sha256_of() {
  [[ -r "$1" ]] || return 0
  sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
}

coh_bool() {
  if [[ "${1:-0}" == '1' ]]; then printf 'true'; else printf 'false'; fi
}

coh_seam_active() {
  [[ "${COHESIVE_TEST_SEAM:-0}" == '1' ]]
}

coh_resolve_identity() {
  local key
  if coh_seam_active; then
    COH_IDENTITY_MODE='test_seam'
    COH_ENTRYPOINT_RESOLVED="${COHESIVE_SEAM_ENTRYPOINT:-$COHESIVE_ENTRYPOINT}"
    COH_ENTRYPOINT_SHA_EXPECTED="${COHESIVE_SEAM_ENTRYPOINT_SHA256:-$COHESIVE_ENTRYPOINT_SHA256}"
    COH_LAUNCHER_RESOLVED="${COHESIVE_SEAM_LAUNCHER:-$COHESIVE_LAUNCHER}"
    COH_LAUNCHER_SHA_EXPECTED="${COHESIVE_SEAM_LAUNCHER_SHA256:-$COHESIVE_LAUNCHER_SHA256}"
    COH_HOME_RESOLVED="${COHESIVE_SEAM_HERMES_HOME:-$COHESIVE_HERMES_HOME}"
    return 0
  fi
  for key in COHESIVE_SEAM_ENTRYPOINT COHESIVE_SEAM_ENTRYPOINT_SHA256 \
    COHESIVE_SEAM_LAUNCHER COHESIVE_SEAM_LAUNCHER_SHA256 COHESIVE_SEAM_HERMES_HOME; do
    if [[ -n "${!key:-}" ]]; then
      die "$key requires COHESIVE_TEST_SEAM=1; the frozen D38 identity is not overridable"
    fi
  done
  COH_IDENTITY_MODE='frozen_default'
  COH_ENTRYPOINT_RESOLVED="$COHESIVE_ENTRYPOINT"
  COH_ENTRYPOINT_SHA_EXPECTED="$COHESIVE_ENTRYPOINT_SHA256"
  COH_LAUNCHER_RESOLVED="$COHESIVE_LAUNCHER"
  COH_LAUNCHER_SHA_EXPECTED="$COHESIVE_LAUNCHER_SHA256"
  COH_HOME_RESOLVED="$COHESIVE_HERMES_HOME"
  return 0
}

coh_resolve_state_dir() {
  local base="${COHESIVE_STATE_DIR:-}"
  if [[ -z "$base" ]]; then
    base="${HERMES_KANBAN_WORKSPACE:-$coh_repo_root}/readiness-evidence/cohesive/live"
  fi
  printf '%s' "$base"
}

coh_resolve_availability_ledger() {
  local base="${COHESIVE_AVAILABILITY_LEDGER:-}"
  if [[ -z "$base" ]]; then
    base="${LWRACQ_STATE_DIR:-${HERMES_KANBAN_WORKSPACE:-$coh_repo_root}/readiness-evidence/live}"
  fi
  printf '%s' "$base"
}

# coh_deadline_valid <requested> <limit>
coh_deadline_valid() {
  local requested="$1" limit="$2"
  [[ "$requested" =~ ^[0-9]+$ ]] || return 1
  ((requested >= 1)) || return 1
  ((limit > COHESIVE_KILL_AFTER_S)) || return 1
  return 0
}

# coh_deadline_clamped <requested> <limit>
coh_deadline_clamped() {
  local requested="$1" limit="$2"
  local ceiling=$((limit - COHESIVE_KILL_AFTER_S))
  ((requested > ceiling)) && requested="$ceiling"
  printf '%s' "$requested"
}

# coh_resolve_validity
#   Requires an explicit whole-second validity window. No approved window value
#   exists in the binding plans, so an absent or malformed value is an unknown
#   freshness and stops instead of being defaulted or inferred.
coh_resolve_validity() {
  local requested="${COHESIVE_VALIDITY_S:-}"
  if [[ -z "$requested" || ! "$requested" =~ ^[0-9]+$ || "$requested" -lt 1 ]]; then
    return 1
  fi
  printf '%s' "$requested"
}

coh_utc_plus() {
  local seconds="$1"
  date -u -d "+${seconds} seconds" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null
}

coh_ledger_hashes() {
  local ledger="$1"
  if [[ -n "$ledger" && -r "$ledger/attempted" ]]; then
    COH_AVAIL_ATTEMPTED_SHA="$(coh_sha256_of "$ledger/attempted")"
  fi
  if [[ -n "$ledger" && -r "$ledger/receipt.json" ]]; then
    COH_AVAIL_RECEIPT_SHA="$(coh_sha256_of "$ledger/receipt.json")"
  fi
}

# coh_client_argv
#   The exact command this capture will run, with the resolved identity so a
#   receipt taken under a test seam is visibly not the frozen default.
coh_client_argv() {
  local entrypoint="${COH_ENTRYPOINT_RESOLVED:-$COHESIVE_ENTRYPOINT}"
  local home="${COH_HOME_RESOLVED:-$COHESIVE_HERMES_HOME}"
  printf 'HERMES_HOME=%s %s %s %s %s' \
    "$home" "$entrypoint" "$COHESIVE_GETTER_VERB" "$COHESIVE_GETTER_SUBVERB" "$COHESIVE_GETTER_LEAF"
}

coh_cleanup() {
  [[ -n "$COH_TMPDIR" && -d "$COH_TMPDIR" ]] && rm -rf -- "$COH_TMPDIR"
  return 0
}

coh_on_signal() {
  # The durable latch already exists at this point: keep it, record the
  # interruption and refuse to continue. No retry is authorised.
  {
    printf 'interrupted_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >>"$COH_STATE_DIR/interrupted" 2>/dev/null || true
  sync
  printf 'cohesive-capture: interrupted; capture latch preserved, no retry permitted\n' >&2
  exit 3
}

coh_emit_bundle() {
  printf '{\n'
  printf '  "schema": "%s",\n' "$COHESIVE_SCHEMA"
  printf '  "finding": "%s",\n' "$COHESIVE_FINDING"
  printf '  "boundary": "%s",\n' "$COHESIVE_BOUNDARY"
  printf '  "status": "%s",\n' "$COH_STATUS"
  printf '  "reason": "%s",\n' "$COH_REASON"
  printf '  "fact": %s,\n' "$(cohesive_json_str_or_null "$COH_FACT")"
  printf '  "attempt_spent": %s,\n' "$(coh_bool "$COH_ATTEMPT_SPENT")"
  printf '  "attempt_id": %s,\n' "$(cohesive_json_str_or_null "$COH_ATTEMPT_ID")"
  printf '  "capture_started_utc": %s,\n' "$(cohesive_json_str_or_null "$COH_START_UTC")"
  printf '  "capture_completed_utc": %s,\n' "$(cohesive_json_str_or_null "$COH_END_UTC")"
  printf '  "freshness": {\n'
  printf '    "validity_s": %s,\n' "$(cohesive_json_int_or_null "$COH_VALIDITY_S")"
  printf '    "expires_at_utc": %s,\n' "$(cohesive_json_str_or_null "$COH_EXPIRES_UTC")"
  printf '    "expiry_rule": "earliest_fact_expiry",\n'
  printf '    "rolling_extension": false,\n'
  printf '    "extension_policy": "a spent bundle is immutable and is never extended by a newer single fact"\n'
  printf '  },\n'
  printf '  "identity": {\n'
  printf '    "mode": "%s",\n' "$COH_IDENTITY_MODE"
  printf '    "entrypoint": %s,\n' "$(cohesive_json_str_or_null "$COH_ENTRYPOINT_RESOLVED")"
  printf '    "entrypoint_sha256_expected": %s,\n' "$(cohesive_json_str_or_null "$COH_ENTRYPOINT_SHA_EXPECTED")"
  printf '    "entrypoint_sha256_before": %s,\n' "$(cohesive_json_str_or_null "$COH_ENTRYPOINT_SHA_BEFORE")"
  printf '    "entrypoint_sha256_after": %s,\n' "$(cohesive_json_str_or_null "$COH_ENTRYPOINT_SHA_AFTER")"
  printf '    "launcher": %s,\n' "$(cohesive_json_str_or_null "$COH_LAUNCHER_RESOLVED")"
  printf '    "launcher_sha256_expected": %s,\n' "$(cohesive_json_str_or_null "$COH_LAUNCHER_SHA_EXPECTED")"
  printf '    "launcher_sha256": %s,\n' "$(cohesive_json_str_or_null "$COH_LAUNCHER_SHA")"
  printf '    "hermes_home": %s,\n' "$(cohesive_json_str_or_null "$COH_HOME_RESOLVED")"
  printf '    "hermes_home_config": %s\n' "$(cohesive_json_str_or_null "$COH_HOME_CONFIG")"
  printf '  },\n'
  printf '  "client": {\n'
  printf '    "command": "%s",\n' "$(coh_client_argv)"
  printf '    "exit": %s,\n' "$(cohesive_json_int_or_null "$COH_CLIENT_EXIT")"
  printf '    "leaf": "%s",\n' "$COHESIVE_GETTER_LEAF"
  printf '    "value": %s,\n' "$(cohesive_json_int_or_null "$COH_CLIENT_VALUE")"
  printf '    "provenance": "selected_nonsecret_config_leaf",\n'
  printf '    "strength": "configured_intent",\n'
  printf '    "effective": "not_established"\n'
  printf '  },\n'
  printf '  "server": {\n'
  printf '    "target": "%s",\n' "$COHESIVE_SSH_TARGET"
  printf '    "endpoints": {"metrics": "%s", "props": "%s", "health": "%s"},\n' \
    "$COHESIVE_METRICS_ENDPOINT" "$COHESIVE_PROPS_ENDPOINT" "$COHESIVE_HEALTH_ENDPOINT"
  printf '    "exit": %s,\n' "$(cohesive_json_int_or_null "$COH_SERVER_EXIT")"
  printf '    "health_status": %s,\n' "$(cohesive_json_int_or_null "$COH_HEALTH_STATUS")"
  printf '    "props_n_ctx": %s,\n' "$(cohesive_json_int_or_null "$COH_PROPS_NCTX")"
  printf '    "props_total_slots": %s,\n' "$(cohesive_json_int_or_null "$COH_PROPS_SLOTS")"
  printf '    "division_or_inference_used": false,\n'
  printf '    "requests_processing": %s,\n' "$(cohesive_json_int_or_null "$COH_PROC")"
  printf '    "requests_deferred": %s,\n' "$(cohesive_json_int_or_null "$COH_DEFER")"
  printf '    "gtidle": {\n'
  printf '      "device": %s,\n' "$(cohesive_json_str_or_null "$COH_GTIDLE_DEVICE")"
  printf '      "unit": %s,\n' "$(cohesive_json_str_or_null "$COH_GTIDLE_UNIT")"
  printf '      "samples": %s,\n' "$COHESIVE_GTIDLE_SAMPLES"
  printf '      "status": [%s, %s],\n' \
    "$(cohesive_json_str_or_null "$COH_GTIDLE_STATUS_1")" \
    "$(cohesive_json_str_or_null "$COH_GTIDLE_STATUS_2")"
  printf '      "residency_ms": [%s, %s],\n' \
    "$(cohesive_json_int_or_null "$COH_GTIDLE_RESIDENCY_1")" \
    "$(cohesive_json_int_or_null "$COH_GTIDLE_RESIDENCY_2")"
  printf '      "idle_verdict": "not_established"\n'
  printf '    },\n'
  printf '    "exits": {"gtidle_read": %s, "health_curl": %s, "props_curl": %s, "props_filter": %s, "props_map": %s, "metrics_curl": %s, "metrics_filter": %s}\n' \
    "$(cohesive_json_int_or_null "$COH_GTIDLE_READ_EXIT")" \
    "$(cohesive_json_int_or_null "$COH_HEALTH_CURL_EXIT")" \
    "$(cohesive_json_int_or_null "$COH_PROPS_CURL_EXIT")" \
    "$(cohesive_json_int_or_null "$COH_PROPS_FILTER_EXIT")" \
    "$(cohesive_json_int_or_null "$COH_PROPS_MAP_EXIT")" \
    "$(cohesive_json_int_or_null "$COH_METRICS_CURL_EXIT")" \
    "$(cohesive_json_int_or_null "$COH_METRICS_FILTER_EXIT")"
  printf '  },\n'
  printf '  "capacity": {\n'
  printf '    "client_vs_per_slot_capacity": %s,\n' "$(cohesive_json_str_or_null "$COH_CAPACITY_RELATION")"
  printf '    "client_strength_used": "configured_intent",\n'
  printf '    "aggregate_divided": false\n'
  printf '  },\n'
  printf '  "availability": {\n'
  printf '    "ledger": %s,\n' "$(cohesive_json_str_or_null "$COH_AVAIL_LEDGER")"
  printf '    "attempted": "%s",\n' "$([[ -n "$COH_AVAIL_ATTEMPTED_SHA" ]] && printf 'present' || printf 'absent')"
  printf '    "attempted_sha256": %s,\n' "$(cohesive_json_str_or_null "$COH_AVAIL_ATTEMPTED_SHA")"
  printf '    "attempted_sha256_after": %s,\n' "$(cohesive_json_str_or_null "$COH_AVAIL_ATTEMPTED_SHA_AFTER")"
  printf '    "receipt_sha256": %s,\n' "$(cohesive_json_str_or_null "$COH_AVAIL_RECEIPT_SHA")"
  printf '    "ledger_unchanged": %s,\n' "$(coh_bool "$COH_AVAIL_UNCHANGED")"
  printf '    "evidence_reused": false\n'
  printf '  },\n'
  printf '  "limits": {\n'
  printf '    "client_limit_s": %s,\n' "$COHESIVE_CLIENT_LIMIT_S"
  printf '    "server_limit_s": %s,\n' "$COHESIVE_SERVER_LIMIT_S"
  printf '    "kill_after_s": %s,\n' "$COHESIVE_KILL_AFTER_S"
  printf '    "total_limit_s": %s,\n' "$COHESIVE_TOTAL_LIMIT_S"
  printf '    "client_deadline_s": %s,\n' "$(cohesive_json_int_or_null "$COH_CLIENT_DEADLINE_S")"
  printf '    "server_deadline_s": %s,\n' "$(cohesive_json_int_or_null "$COH_SERVER_DEADLINE_S")"
  printf '    "client_elapsed_ms": %s,\n' "$(cohesive_json_int_or_null "$COH_CLIENT_ELAPSED_MS")"
  printf '    "server_elapsed_ms": %s,\n' "$(cohesive_json_int_or_null "$COH_SERVER_ELAPSED_MS")"
  printf '    "retries": %s\n' "$COHESIVE_RETRIES"
  printf '  },\n'
  printf '  "readiness": "not_established",\n'
  printf '  "not_promoted": ["availability_receipt", "configured_intent_to_effective", "gtidle_state_to_idle_window", "server_per_slot_to_client_field"],\n'
  printf '  "runner_sha256": %s,\n' "$(cohesive_json_str_or_null "$COH_RUNNER_SHA")"
  printf '  "lib_sha256": %s\n' "$(cohesive_json_str_or_null "$COH_LIB_SHA")"
  printf '}\n'
}

coh_publish_bundle() {
  local target="$COH_STATE_DIR/bundle.json" tmp="$COH_STATE_DIR/.bundle.json.$$"
  coh_emit_bundle >"$tmp" || die "cannot write bundle"
  mv -f "$tmp" "$target" || die "cannot publish bundle"
  sync
  cat "$target"
}

# coh_preconditions
#   Every check that needs no capture at all: a failure here spends nothing and
#   issues zero reads, so it is not a retry of anything. Returns 0 to proceed.
coh_preconditions() {
  local validity

  COH_AVAIL_LEDGER="$(coh_resolve_availability_ledger)"

  if ! validity="$(coh_resolve_validity)"; then
    COH_STATUS='HOLD'
    COH_REASON='freshness_unknown'
    COH_FACT='precondition:freshness'
    return 1
  fi
  COH_VALIDITY_S="$validity"

  if [[ ! -e "$COH_ENTRYPOINT_RESOLVED" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='identity_unknown'
    COH_FACT='precondition:identity'
    return 1
  fi
  COH_ENTRYPOINT_SHA_BEFORE="$(coh_sha256_of "$COH_ENTRYPOINT_RESOLVED")"
  if [[ -z "$COH_ENTRYPOINT_SHA_BEFORE" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='identity_unknown'
    COH_FACT='precondition:identity'
    return 1
  fi
  if [[ -n "$COH_ENTRYPOINT_SHA_EXPECTED" && "$COH_ENTRYPOINT_SHA_BEFORE" != "$COH_ENTRYPOINT_SHA_EXPECTED" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='identity_mismatch'
    COH_FACT='precondition:identity'
    return 1
  fi

  if [[ -e "$COH_LAUNCHER_RESOLVED" ]]; then
    COH_LAUNCHER_SHA="$(coh_sha256_of "$COH_LAUNCHER_RESOLVED")"
  fi
  if [[ -z "$COH_LAUNCHER_SHA" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='identity_unknown'
    COH_FACT='precondition:identity'
    return 1
  fi
  if [[ -n "$COH_LAUNCHER_SHA_EXPECTED" && "$COH_LAUNCHER_SHA" != "$COH_LAUNCHER_SHA_EXPECTED" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='identity_mismatch'
    COH_FACT='precondition:identity'
    return 1
  fi

  if [[ -d "$COH_HOME_RESOLVED" && -f "$COH_HOME_RESOLVED/$COHESIVE_PROFILE_CONFIG_NAME" ]]; then
    COH_HOME_CONFIG="$COHESIVE_PROFILE_CONFIG_NAME"
  else
    COH_HOME_CONFIG=''
    COH_STATUS='HOLD'
    COH_REASON='identity_unknown'
    COH_FACT='precondition:identity'
    return 1
  fi

  if [[ ! -e "$COH_AVAIL_LEDGER/attempted" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='availability_not_established'
    COH_FACT='precondition:availability'
    return 1
  fi
  coh_ledger_hashes "$COH_AVAIL_LEDGER"
  if [[ -z "$COH_AVAIL_ATTEMPTED_SHA" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='availability_not_established'
    COH_FACT='precondition:availability'
    return 1
  fi

  if [[ -e "$COH_STATE_DIR/attempted" || -e "$COH_STATE_DIR/bundle.json" ]]; then
    COH_STATUS='REFUSED'
    COH_REASON='latch_present'
    COH_FACT='precondition:latch'
    return 1
  fi

  return 0
}

coh_run_client() {
  local start_ms exit_code

  start_ms="$(date +%s%3N)"
  HERMES_HOME="$COH_HOME_RESOLVED" \
    timeout --signal=TERM --kill-after="${COHESIVE_KILL_AFTER_S}s" "${COH_CLIENT_DEADLINE_S}s" \
    "$COH_ENTRYPOINT_RESOLVED" "$COHESIVE_GETTER_VERB" "$COHESIVE_GETTER_SUBVERB" "$COHESIVE_GETTER_LEAF" \
    >"$COH_TMPDIR/client.frame" 2>/dev/null
  exit_code=$?
  COH_CLIENT_EXIT="$exit_code"
  COH_CLIENT_ELAPSED_MS=$(($(date +%s%3N) - start_ms))

  if ((COH_CLIENT_ELAPSED_MS > COHESIVE_CLIENT_LIMIT_S * 1000)); then
    COH_STATUS='HOLD'
    COH_REASON='deadline_exceeded'
    COH_FACT='client'
    return 1
  fi
  if ((exit_code == 124 || exit_code == 137)); then
    COH_STATUS='HOLD'
    COH_REASON='deadline_exceeded'
    COH_FACT='client'
    return 1
  fi
  if ((exit_code != 0)); then
    COH_STATUS='HOLD'
    COH_REASON='client_getter_failed'
    COH_FACT='client'
    return 1
  fi

  cohesive_validate_client_frame "$COH_TMPDIR/client.frame"
  [[ "$COH_STATUS" == 'CAPTURED' ]]
}

coh_run_server() {
  local start_ms exit_code remote_script remote_cmd

  remote_script="$(cohesive_build_remote_script)"
  remote_cmd="bash -c $(printf '%q' "$remote_script")"

  start_ms="$(date +%s%3N)"
  timeout --signal=TERM --kill-after="${COHESIVE_KILL_AFTER_S}s" "${COH_SERVER_DEADLINE_S}s" \
    ssh -o BatchMode=yes "$COHESIVE_SSH_TARGET" "$remote_cmd" \
    >"$COH_TMPDIR/server.frame" 2>/dev/null
  exit_code=$?
  COH_SERVER_EXIT="$exit_code"
  COH_SERVER_ELAPSED_MS=$(($(date +%s%3N) - start_ms))

  if ((COH_SERVER_ELAPSED_MS > COHESIVE_SERVER_LIMIT_S * 1000)); then
    COH_STATUS='HOLD'
    COH_REASON='deadline_exceeded'
    COH_FACT='server'
    return 1
  fi
  if ((exit_code == 124 || exit_code == 137)); then
    COH_STATUS='HOLD'
    COH_REASON='deadline_exceeded'
    COH_FACT='server'
    return 1
  fi
  if ((exit_code != 0)); then
    COH_STATUS='HOLD'
    COH_REASON='transport_failure'
    COH_FACT='server'
    return 1
  fi

  cohesive_validate_server_frame "$COH_TMPDIR/server.frame"
  [[ "$COH_STATUS" == 'CAPTURED' ]]
}

coh_cmd_capture() {
  local latch_tmp ledger_after
  local requested_client="${COHESIVE_CLIENT_DEADLINE_S:-$COHESIVE_DEFAULT_CLIENT_DEADLINE_S}"
  local requested_server="${COHESIVE_SERVER_DEADLINE_S:-$COHESIVE_DEFAULT_SERVER_DEADLINE_S}"

  # Deadlines are validated before anything at all happens, so a malformed
  # override is a local usage error and never a partially attempted capture.
  coh_deadline_valid "$requested_client" "$COHESIVE_CLIENT_LIMIT_S" ||
    die "COHESIVE_CLIENT_DEADLINE_S must be a whole number of seconds, at least 1"
  coh_deadline_valid "$requested_server" "$COHESIVE_SERVER_LIMIT_S" ||
    die "COHESIVE_SERVER_DEADLINE_S must be a whole number of seconds, at least 1"
  COH_CLIENT_DEADLINE_S="$(coh_deadline_clamped "$requested_client" "$COHESIVE_CLIENT_LIMIT_S")"
  COH_SERVER_DEADLINE_S="$(coh_deadline_clamped "$requested_server" "$COHESIVE_SERVER_LIMIT_S")"

  coh_resolve_identity
  COH_STATE_DIR="$(coh_resolve_state_dir)"
  COH_RUNNER_SHA="$(coh_sha256_of "${BASH_SOURCE[0]}")"
  COH_LIB_SHA="$(coh_sha256_of "$coh_script_dir/cohesive-lib.sh")"
  COH_START_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if ! coh_preconditions; then
    COH_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    coh_emit_bundle
    if [[ "$COH_STATUS" == 'REFUSED' ]]; then
      printf 'cohesive-capture: refusing; capture latch already held in %s\n' "$COH_STATE_DIR" >&2
      return 3
    fi
    printf 'cohesive-capture: stopping before any read (%s); nothing spent\n' "$COH_REASON" >&2
    return 2
  fi

  COH_EXPIRES_UTC="$(coh_utc_plus "$COH_VALIDITY_S")"

  mkdir -p "$COH_STATE_DIR" || die "cannot create state dir: $COH_STATE_DIR"
  chmod 700 "$COH_STATE_DIR" 2>/dev/null || true

  # The one-capture latch is durable BEFORE the first read and is never removed.
  COH_ATTEMPT_ID="attempt-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  latch_tmp="$COH_STATE_DIR/.attempted.$$"
  {
    printf 'attempt_id=%s\n' "$COH_ATTEMPT_ID"
    printf 'started_at_utc=%s\n' "$COH_START_UTC"
    printf 'validity_s=%s\n' "$COH_VALIDITY_S"
    printf 'client_limit_s=%s\n' "$COHESIVE_CLIENT_LIMIT_S"
    printf 'server_limit_s=%s\n' "$COHESIVE_SERVER_LIMIT_S"
    printf 'total_limit_s=%s\n' "$COHESIVE_TOTAL_LIMIT_S"
    printf 'runner_sha256=%s\n' "$COH_RUNNER_SHA"
  } >"$latch_tmp" || die "cannot write latch"
  sync
  mv -f "$latch_tmp" "$COH_STATE_DIR/attempted" || die "cannot publish latch"
  sync
  COH_ATTEMPT_SPENT=1

  COH_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/cohcohesive.XXXXXX")" || die "cannot create private temp dir"
  trap coh_cleanup EXIT
  trap coh_on_signal INT TERM

  if ! coh_run_client; then
    COH_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    coh_publish_bundle
    return 2
  fi

  if ! coh_run_server; then
    COH_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    coh_publish_bundle
    return 2
  fi

  COH_CAPACITY_RELATION="$(cohesive_capacity_relation "$COH_CLIENT_VALUE" "$COH_PROPS_NCTX")"

  COH_ENTRYPOINT_SHA_AFTER="$(coh_sha256_of "$COH_ENTRYPOINT_RESOLVED")"
  COH_AVAIL_UNCHANGED=0
  ledger_after="$(coh_sha256_of "$COH_AVAIL_LEDGER/attempted")"
  COH_AVAIL_ATTEMPTED_SHA_AFTER="$ledger_after"
  if [[ -n "$ledger_after" && "$ledger_after" == "$COH_AVAIL_ATTEMPTED_SHA" ]]; then
    COH_AVAIL_UNCHANGED=1
  fi

  COH_END_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$COH_CAPACITY_RELATION" != 'equal' ]]; then
    COH_STATUS='HOLD'
    COH_REASON='capacity_mismatch'
    COH_FACT='bundle'
  elif [[ -z "$COH_ENTRYPOINT_SHA_AFTER" || "$COH_ENTRYPOINT_SHA_AFTER" != "$COH_ENTRYPOINT_SHA_BEFORE" ]]; then
    COH_STATUS='HOLD'
    COH_REASON='identity_changed'
    COH_FACT='bundle'
  elif ((!COH_AVAIL_UNCHANGED)); then
    COH_STATUS='HOLD'
    COH_REASON='availability_latch_modified'
    COH_FACT='bundle'
  fi

  coh_publish_bundle
  [[ "$COH_STATUS" == 'CAPTURED' ]] && return 0
  return 2
}

coh_cmd_wire() {
  printf 'client argv:\n'
  cohesive_build_client_argv
  printf '\nserver remote script:\n'
  cohesive_build_remote_script
}

coh_cmd_status() {
  local state_dir ledger bundle='' expires='' validity='unknown'
  state_dir="$1"
  ledger="$(coh_resolve_availability_ledger)"

  printf 'state_dir=%s\n' "$state_dir"
  if [[ -e "$state_dir/attempted" ]]; then
    printf 'attempted=present\n'
    grep -m1 '^attempt_id=' "$state_dir/attempted" 2>/dev/null || true
    grep -m1 '^started_at_utc=' "$state_dir/attempted" 2>/dev/null || true
  else
    printf 'attempted=absent\n'
  fi
  if [[ -e "$state_dir/bundle.json" ]]; then
    bundle='present'
    printf 'bundle=present\n'
    expires="$(grep -m1 '"expires_at_utc":' "$state_dir/bundle.json" 2>/dev/null | cut -d'"' -f4 || true)"
    [[ -n "$expires" ]] && printf 'expires_at_utc=%s\n' "$expires"
    if [[ -n "$expires" ]]; then
      if [[ "$expires" > "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
        validity='current'
      else
        validity='expired'
      fi
    fi
  else
    printf 'bundle=absent\n'
  fi
  printf 'validity=%s\n' "$validity"
  [[ -e "$state_dir/interrupted" ]] && printf 'interrupted=present\n' || printf 'interrupted=absent\n'
  printf 'availability_ledger=%s\n' "$ledger"
  if [[ -e "$ledger/attempted" ]]; then
    printf 'availability_attempted=present\n'
  else
    printf 'availability_attempted=absent\n'
  fi
  if [[ -e "$state_dir/attempted" || -e "$state_dir/bundle.json" ]]; then
    printf 'latch=held\n'
    return 3
  fi
  printf 'latch=clear\n'
  return 0
}

coh_main() {
  local subcommand="${1:-capture}"
  case "$subcommand" in
    capture)
      coh_cmd_capture
      ;;
    wire)
      coh_cmd_wire
      ;;
    status)
      coh_cmd_status "$(coh_resolve_state_dir)"
      ;;
    '--help' | '-h' | help)
      usage
      ;;
    *)
      die "unknown subcommand: $subcommand"
      ;;
  esac
}

coh_main "$@"
