#!/usr/bin/env bash
# LWRACQ-20261014-v2 section 3.2 acquisition driver: ONE bounded, non-generating,
# availability-only read of the existing loopback llama.cpp metrics surface.
#
# Scope of authority (all of it): one GET, zero curl retries, 3s connect,
# 10s request, whole supervised remote operation <=30s including connection and
# cleanup. It performs no server transaction, no activation, no install/reload,
# no /slots, /props, GPU, health or log read, no sudo, no inference and no D17
# reservation. A non-accepted result is HOLD-METRICS-LIVE: no second request, no
# automatic flag enablement and no fallback endpoint.
#
# The one-GET latch is written durably BEFORE the request and is never removed
# by this runner. Any later invocation refuses with zero requests, so an
# interrupted, killed or uncertain read cannot be retried.
#
# Offline preparation only: until the independent verifier explicitly ACCEPTs
# this exact preparation, 'run' must not be executed. 'wire' and 'status' are
# read-only local operations and never contact the server.
#
# Usage:
#   metrics-availability.sh run      # the single GET (only after ACCEPT)
#   metrics-availability.sh wire     # print the frozen remote script; no GET
#   metrics-availability.sh status   # print the durable latch state; no GET
#
# Environment:
#   LWRACQ_STATE_DIR    durable latch/receipt dir (default:
#                       "${HERMES_KANBAN_WORKSPACE:-<repo root>}/readiness-evidence/live")
#   LWRACQ_DEADLINE_S   supervisor deadline in whole seconds; clamped to
#                       <= total_limit - kill_after so the hard bound of
#                       LWRACQ_TOTAL_LIMIT_S seconds can never be exceeded
#
# Exit codes: 0 ACCEPTED, 2 HOLD (typed reason), 3 REFUSED (latch held, no GET),
#             4 usage or local configuration error.

set -u
set -o pipefail

lwracq_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=readiness-evidence/metrics-availability-lib.sh
source "$lwracq_script_dir/metrics-availability-lib.sh"

lwracq_repo_root="$(cd "$lwracq_script_dir/.." && pwd)"

LW_STATUS='HOLD'
LW_REASON='none'
LW_CURL_EXIT=''
LW_FILTER_EXIT=''
LW_PROC=''
LW_DEFER=''
LW_SSH_EXIT=''
LW_ELAPSED_MS=''
LW_GET_PERFORMED=0
LW_ATTEMPT_ID=''
LW_CAPTURE_TIME=''
LW_DEADLINE="$LWRACQ_DEFAULT_DEADLINE_S"
LW_STATE_DIR=''
LW_RUNNER_SHA=''
LW_LIB_SHA=''
LW_TMPDIR=''

usage() {
  cat <<'EOF'
Usage: metrics-availability.sh [run|wire|status]

  run     Perform the single bounded metrics-availability GET. Only valid after
          the independent verifier explicitly ACCEPTs this preparation.
  wire    Print the frozen remote script (offline; never contacts the server).
  status  Print the durable one-GET latch state (offline; never contacts).
EOF
}

die() {
  printf 'metrics-availability: %s\n' "$1" >&2
  exit 4
}

lwracq_sha256_of() {
  [[ -r "$1" ]] || return 0
  sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
}

lwracq_resolve_state_dir() {
  local base="${LWRACQ_STATE_DIR:-}"
  if [[ -z "$base" ]]; then
    base="${HERMES_KANBAN_WORKSPACE:-$lwracq_repo_root}/readiness-evidence/live"
  fi
  printf '%s' "$base"
}

lwracq_resolve_deadline() {
  local requested="${LWRACQ_DEADLINE_S:-$LWRACQ_DEFAULT_DEADLINE_S}"
  local ceiling=$((LWRACQ_TOTAL_LIMIT_S - LWRACQ_KILL_AFTER_S))
  [[ "$requested" =~ ^[0-9]+$ ]] || die "LWRACQ_DEADLINE_S must be a whole number of seconds"
  ((requested >= 1)) || die "LWRACQ_DEADLINE_S must be at least 1"
  ((requested > ceiling)) && requested="$ceiling"
  printf '%s' "$requested"
}

lwracq_json_str_or_null() {
  if [[ -n "$1" ]]; then
    printf '"%s"' "$1"
  else
    printf 'null'
  fi
}

lwracq_json_int_or_null() {
  if [[ "$1" =~ ^[0-9]{1,9}$ ]]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}

lwracq_emit_receipt() {
  printf '{\n'
  printf '  "schema": "%s",\n' "$LWRACQ_SCHEMA"
  printf '  "finding": "%s",\n' "$LWRACQ_FINDING"
  printf '  "boundary": "%s",\n' "$LWRACQ_BOUNDARY"
  printf '  "status": "%s",\n' "$LW_STATUS"
  printf '  "reason": "%s",\n' "$LW_REASON"
  if ((LW_GET_PERFORMED)); then
    printf '  "get_performed": true,\n'
  else
    printf '  "get_performed": false,\n'
  fi
  printf '  "attempt_id": %s,\n' "$(lwracq_json_str_or_null "$LW_ATTEMPT_ID")"
  printf '  "capture_time_utc": %s,\n' "$(lwracq_json_str_or_null "$LW_CAPTURE_TIME")"
  printf '  "transport": {\n'
  printf '    "label": "%s",\n' "$LWRACQ_SSH_TARGET"
  printf '    "ssh_exit": %s,\n' "$(lwracq_json_int_or_null "$LW_SSH_EXIT")"
  printf '    "elapsed_ms": %s,\n' "$(lwracq_json_int_or_null "$LW_ELAPSED_MS")"
  printf '    "deadline_s": %s,\n' "$LW_DEADLINE"
  printf '    "total_limit_s": %s\n' "$LWRACQ_TOTAL_LIMIT_S"
  printf '  },\n'
  printf '  "wire": {\n'
  printf '    "endpoint": "%s",\n' "$LWRACQ_ENDPOINT"
  printf '    "connect_timeout_s": %s,\n' "$LWRACQ_CONNECT_TIMEOUT_S"
  printf '    "request_timeout_s": %s,\n' "$LWRACQ_REQUEST_TIMEOUT_S"
  printf '    "retries": %s\n' "$LWRACQ_CURL_RETRIES"
  printf '  },\n'
  printf '  "curl_exit": %s,\n' "$(lwracq_json_int_or_null "$LW_CURL_EXIT")"
  printf '  "filter_exit": %s,\n' "$(lwracq_json_int_or_null "$LW_FILTER_EXIT")"
  printf '  "requests_processing": %s,\n' "$(lwracq_json_int_or_null "$LW_PROC")"
  printf '  "requests_deferred": %s,\n' "$(lwracq_json_int_or_null "$LW_DEFER")"
  printf '  "runner_sha256": %s,\n' "$(lwracq_json_str_or_null "$LW_RUNNER_SHA")"
  printf '  "lib_sha256": %s\n' "$(lwracq_json_str_or_null "$LW_LIB_SHA")"
  printf '}\n'
}

lwracq_publish_receipt() {
  local target="$LW_STATE_DIR/receipt.json" tmp="$LW_STATE_DIR/.receipt.json.$$"
  lwracq_emit_receipt >"$tmp" || die "cannot write receipt"
  mv -f "$tmp" "$target" || die "cannot publish receipt"
  sync
  cat "$target"
}

lwracq_cleanup() {
  [[ -n "$LW_TMPDIR" && -d "$LW_TMPDIR" ]] && rm -rf -- "$LW_TMPDIR"
  return 0
}

lwracq_on_signal() {
  # The durable latch already exists at this point: keep it, record the
  # interruption and refuse to continue. No retry is authorised.
  {
    printf 'interrupted_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >>"$LW_STATE_DIR/interrupted" 2>/dev/null || true
  sync
  printf 'metrics-availability: interrupted; one-GET latch preserved, no retry permitted\n' >&2
  exit 3
}

lwracq_cmd_wire() {
  lwracq_build_remote_script
}

lwracq_cmd_status() {
  local state_dir="$1"
  printf 'state_dir=%s\n' "$state_dir"
  if [[ -e "$state_dir/attempted" ]]; then
    printf 'attempted=present\n'
    grep -m1 '^attempt_id=' "$state_dir/attempted" 2>/dev/null || true
    grep -m1 '^started_at_utc=' "$state_dir/attempted" 2>/dev/null || true
  else
    printf 'attempted=absent\n'
  fi
  [[ -e "$state_dir/receipt.json" ]] && printf 'receipt=present\n' || printf 'receipt=absent\n'
  [[ -e "$state_dir/interrupted" ]] && printf 'interrupted=present\n' || printf 'interrupted=absent\n'
  if [[ -e "$state_dir/attempted" || -e "$state_dir/receipt.json" ]]; then
    printf 'latch=held\n'
    return 3
  fi
  printf 'latch=clear\n'
  return 0
}

lwracq_cmd_run() {
  local state_dir deadline started_at_utc start_ms ssh_exit remote_script remote_cmd
  local latch_tmp

  state_dir="$(lwracq_resolve_state_dir)"
  LW_STATE_DIR="$state_dir"
  deadline="$(lwracq_resolve_deadline)"
  LW_DEADLINE="$deadline"
  LW_RUNNER_SHA="$(lwracq_sha256_of "${BASH_SOURCE[0]}")"
  LW_LIB_SHA="$(lwracq_sha256_of "$lwracq_script_dir/metrics-availability-lib.sh")"

  mkdir -p "$state_dir" || die "cannot create state dir: $state_dir"
  chmod 700 "$state_dir" 2>/dev/null || true

  started_at_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  LW_CAPTURE_TIME="$started_at_utc"

  # One-GET latch: any prior attempt or receipt means the single authorised
  # request has already been spent, whatever its outcome was. The existing
  # receipt must never be overwritten by a refusal, so this path only reports.
  if [[ -e "$state_dir/attempted" || -e "$state_dir/receipt.json" ]]; then
    LW_STATUS='REFUSED'
    LW_REASON='latch_present'
    lwracq_emit_receipt
    printf 'metrics-availability: refusing; one-GET latch already held in %s\n' "$state_dir" >&2
    return 3
  fi

  LW_TMPDIR="$(mktemp -d "${TMPDIR:-/tmp}/lwracq-metrics.XXXXXX")" || die "cannot create private temp dir"
  trap lwracq_cleanup EXIT
  trap lwracq_on_signal INT TERM

  LW_ATTEMPT_ID="attempt-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  latch_tmp="$state_dir/.attempted.$$"
  {
    printf 'attempt_id=%s\n' "$LW_ATTEMPT_ID"
    printf 'started_at_utc=%s\n' "$started_at_utc"
    printf 'deadline_s=%s\n' "$deadline"
    printf 'total_limit_s=%s\n' "$LWRACQ_TOTAL_LIMIT_S"
    printf 'runner_sha256=%s\n' "$LW_RUNNER_SHA"
  } >"$latch_tmp" || die "cannot write latch"
  sync
  mv -f "$latch_tmp" "$state_dir/attempted" || die "cannot publish latch"
  sync

  remote_script="$(lwracq_build_remote_script)"
  remote_cmd="bash -c $(printf '%q' "$remote_script")"

  LW_GET_PERFORMED=1
  start_ms="$(date +%s%3N)"
  timeout --signal=TERM --kill-after="${LWRACQ_KILL_AFTER_S}s" "${deadline}s" \
    ssh -o BatchMode=yes "$LWRACQ_SSH_TARGET" "$remote_cmd" \
    >"$LW_TMPDIR/frame" 2>/dev/null
  ssh_exit=$?
  LW_SSH_EXIT="$ssh_exit"
  LW_ELAPSED_MS=$(($(date +%s%3N) - start_ms))

  LW_CAPTURE_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if ((LW_ELAPSED_MS > LWRACQ_TOTAL_LIMIT_S * 1000)); then
    LW_STATUS='HOLD'
    LW_REASON='deadline_exceeded'
  elif ((ssh_exit == 124 || ssh_exit == 137)); then
    LW_STATUS='HOLD'
    LW_REASON='deadline_exceeded'
  elif ((ssh_exit != 0)); then
    LW_STATUS='HOLD'
    LW_REASON='transport_failure'
  else
    lwracq_validate_frame "$LW_TMPDIR/frame"
  fi

  lwracq_publish_receipt
  [[ "$LW_STATUS" == 'ACCEPTED' ]] && return 0
  return 2
}

lwracq_main() {
  local subcommand="${1:-run}"
  case "$subcommand" in
    run)
      lwracq_cmd_run
      ;;
    wire)
      lwracq_cmd_wire
      ;;
    status)
      lwracq_cmd_status "$(lwracq_resolve_state_dir)"
      ;;
    '--help' | '-h' | help)
      usage
      ;;
    *)
      die "unknown subcommand: $subcommand"
      ;;
  esac
}

lwracq_main "$@"
