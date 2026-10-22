#!/usr/bin/env bash
# LWRACQ-20261014-v2 section 3.2 - frozen wire contract and pure output
# validator for the single bounded metrics-availability read (finding
# CI-LWR-001).
#
# Sourced by readiness-evidence/metrics-availability.sh (the acquisition
# driver) and by readiness-evidence/tests/run-metrics-availability-tests.sh
# (the offline synthetic suite). This file performs no network I/O, no
# persistence and no logging: it only builds the frozen remote command string
# and turns an already server-side-filtered frame into a typed decision.
#
# Privacy boundary: the unfiltered /metrics body, arbitrary remote stderr and
# remote banners must never reach the driver, a receipt or a terminal. Only the
# two documented llama.cpp queue gauges may cross the wire, and the validator
# rejects anything else rather than passing it through or sanitising it.

[[ -n "${LWRACQ_LIB_LOADED:-}" ]] && return 0
LWRACQ_LIB_LOADED=1

set -o pipefail

readonly LWRACQ_SCHEMA='lwracq-metrics-availability/v1'
readonly LWRACQ_FINDING='CI-LWR-001'
readonly LWRACQ_BOUNDARY='LWRACQ-20261014-v2#3.2'

# Existing authorised read-only access to the existing loopback metrics
# surface. No new credential, host discovery, sudo, port or endpoint is
# introduced by this preparation.
readonly LWRACQ_SSH_TARGET='dsaw@192.168.8.12'
readonly LWRACQ_ENDPOINT='http://127.0.0.1:8093/metrics'

# Frozen transport bounds: one GET, zero retries, connect <=3s, request <=10s,
# whole supervised remote operation <=30s including connection and cleanup.
readonly LWRACQ_CONNECT_TIMEOUT_S=3
readonly LWRACQ_REQUEST_TIMEOUT_S=10
readonly LWRACQ_CURL_RETRIES=0
readonly LWRACQ_TOTAL_LIMIT_S=30
readonly LWRACQ_DEFAULT_DEADLINE_S=29
readonly LWRACQ_KILL_AFTER_S=1

readonly LWRACQ_FRAME_HEADER='LWRACQ-METRICS-V1'
readonly LWRACQ_STATUS_CURL='curl_exit'
readonly LWRACQ_STATUS_FILTER='filter_exit'

readonly LWRACQ_GAUGE_PROCESSING='llamacpp:requests_processing'
readonly LWRACQ_GAUGE_DEFERRED='llamacpp:requests_deferred'

# The one frozen server-side narrowing: only the two documented scalar names
# with a numeric value, anchored on both ends, may leave the server. It carries
# no request body, no /slots access and no other endpoint.
readonly LWRACQ_WIRE_PATTERN='^llamacpp:requests_(processing|deferred)[[:space:]]+[0-9]+([.][0-9]+)?([eE][+-]?[0-9]+)?[[:space:]]*$'

# The accepted typed gauge value: an integral, non-negative, plain decimal
# count. Decimal or exponent spellings pass the wire narrowing above but are
# rejected here as non-canonical, which stops the read instead of normalising
# an unverified representation.
readonly LWRACQ_INTEGER_RE='(0|[1-9][0-9]*)'

# lwracq_build_remote_script
#   Prints the exact remote script the driver hands to ssh. The frame header is
#   emitted first so any remote banner or startup noise lands before it and is
#   rejected as banner content; the two pipeline exits are emitted last from
#   PIPESTATUS so curl's and grep's exits are both inspected, not grep's alone.
lwracq_build_remote_script() {
  cat <<EOF
set -o pipefail
printf '%s\n' '${LWRACQ_FRAME_HEADER}'
curl -fsS --retry ${LWRACQ_CURL_RETRIES} --connect-timeout ${LWRACQ_CONNECT_TIMEOUT_S} --max-time ${LWRACQ_REQUEST_TIMEOUT_S} '${LWRACQ_ENDPOINT}' 2>/dev/null | grep -E '${LWRACQ_WIRE_PATTERN}'
lwracq_pipe_status=("\${PIPESTATUS[@]}")
printf '${LWRACQ_STATUS_CURL}=%s\n' "\${lwracq_pipe_status[0]}"
printf '${LWRACQ_STATUS_FILTER}=%s\n' "\${lwracq_pipe_status[1]}"
EOF
}

# lwracq_validate_frame <frame-file>
#   Reads an already server-side-filtered frame and sets:
#     LW_STATUS  ACCEPTED | HOLD
#     LW_REASON  none | banner | unsafe_frame | curl_exit_nonzero |
#                filter_no_match | filter_error | unsafe_label |
#                unsafe_value | unsafe_name | duplicate_gauge | missing_gauge
#     LW_CURL_EXIT, LW_FILTER_EXIT, LW_PROC, LW_DEFER
#   It never prints, returns or writes any frame content. Always returns 0; the
#   caller decides the process exit status from LW_STATUS.
lwracq_validate_frame() {
  local frame="$1"
  local -a lines=()
  local i line header_index=-1
  local curl_raw='' filter_raw='' curl_seen=0 filter_seen=0
  local processing='' deferred='' proc_seen=0 defer_seen=0

  LW_STATUS='HOLD'
  LW_REASON='unsafe_frame'
  LW_CURL_EXIT=''
  LW_FILTER_EXIT=''
  LW_PROC=''
  LW_DEFER=''

  [[ -r "$frame" ]] || return 0
  mapfile -t lines < "$frame"
  ((${#lines[@]})) || return 0

  # Pass 1 - frame structure: exactly one header, and nothing may precede it.
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [[ "${lines[i]}" == "$LWRACQ_FRAME_HEADER" ]]; then
      header_index=$i
      break
    fi
  done
  if ((header_index < 0)); then
    for line in "${lines[@]}"; do
      [[ -n "$line" ]] && LW_REASON='banner'
    done
    return 0
  fi
  ((header_index > 0)) && { LW_REASON='banner'; return 0; }

  # Pass 1 - transport status lines: exactly one each, integer values only.
  for ((i = 1; i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    if [[ "$line" == "$LWRACQ_FRAME_HEADER" ]]; then
      # A second framed response would mean more than one GET was serviced.
      LW_REASON='unsafe_frame'
      return 0
    fi
    if [[ "$line" != "${LWRACQ_STATUS_CURL}="* && "$line" != "${LWRACQ_STATUS_FILTER}="* ]]; then
      continue
    fi
    if [[ "$line" != "${LWRACQ_STATUS_CURL}="* ]]; then
      [[ "${line#*=}" =~ ^[0-9]{1,4}$ ]] || { LW_REASON='unsafe_frame'; return 0; }
      ((filter_seen)) && { LW_REASON='unsafe_frame'; return 0; }
      filter_seen=1
      filter_raw="${line#*=}"
    else
      [[ "${line#*=}" =~ ^[0-9]{1,4}$ ]] || { LW_REASON='unsafe_frame'; return 0; }
      ((curl_seen)) && { LW_REASON='unsafe_frame'; return 0; }
      curl_seen=1
      curl_raw="${line#*=}"
    fi
  done
  ((curl_seen && filter_seen)) || { LW_REASON='unsafe_frame'; return 0; }
  LW_CURL_EXIT="$curl_raw"
  LW_FILTER_EXIT="$filter_raw"

  # Pass 2 - both pipeline exits, not grep alone.
  ((curl_raw != 0)) && { LW_REASON='curl_exit_nonzero'; return 0; }
  ((filter_raw == 1)) && { LW_REASON='filter_no_match'; return 0; }
  ((filter_raw > 1)) && { LW_REASON='filter_error'; return 0; }

  # Pass 3 - payload: canonical typed gauges only, each exactly once.
  for ((i = 1; i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    [[ "$line" == "${LWRACQ_STATUS_CURL}="* || "$line" == "${LWRACQ_STATUS_FILTER}="* ]] && continue
    if [[ "$line" =~ ^${LWRACQ_GAUGE_PROCESSING}[[:space:]]+${LWRACQ_INTEGER_RE}$ ]]; then
      ((proc_seen)) && { LW_REASON='duplicate_gauge'; return 0; }
      proc_seen=1
      processing="${BASH_REMATCH[1]}"
      continue
    fi
    if [[ "$line" =~ ^${LWRACQ_GAUGE_DEFERRED}[[:space:]]+${LWRACQ_INTEGER_RE}$ ]]; then
      ((defer_seen)) && { LW_REASON='duplicate_gauge'; return 0; }
      defer_seen=1
      deferred="${BASH_REMATCH[1]}"
      continue
    fi
    case "$line" in
      '') LW_REASON='unsafe_frame' ;;
      *'{'* | *'}'*) LW_REASON='unsafe_label' ;;
      "$LWRACQ_GAUGE_PROCESSING"[[:space:]]* | "$LWRACQ_GAUGE_DEFERRED"[[:space:]]*) LW_REASON='unsafe_value' ;;
      *) LW_REASON='unsafe_name' ;;
    esac
    return 0
  done
  ((proc_seen && defer_seen)) || { LW_REASON='missing_gauge'; return 0; }

  # Pass 4 - accepted: exactly one finite non-negative integral value each.
  LW_STATUS='ACCEPTED'
  LW_REASON='none'
  LW_PROC="$processing"
  LW_DEFER="$deferred"
  return 0
}
