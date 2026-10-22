#!/usr/bin/env bash
# LWRACQ-20261014-v2 #3.3 - frozen contract and pure output validators for the
# ONE cohesive privacy-safe scalar readiness capture (finding CI-LWR-001).
#
# Sourced by readiness-evidence/cohesive/cohesive-capture.sh (the preparation
# driver) and by readiness-evidence/cohesive/tests.sh (the offline synthetic
# suite). This file performs no network I/O, no persistence and no logging: it
# builds the frozen command strings and turns an already server-side-narrowed
# frame into typed facts and a typed decision.
#
# Privacy boundary: the unfiltered /props or /metrics body, arbitrary remote
# stderr and remote banners must never reach the driver, a bundle or a terminal.
# Only the documented scalar keys below may cross the wire, every extraction is
# anchored server-side, and the validators reject anything else rather than
# passing it through, sanitising it or normalising it into a value.
#
# Reuse, not replacement: the two gauge names, the anchored gauge pattern, the
# endpoint, the ssh target and the 3s connect / 10s request / zero-retry / 30s
# supervised shape all come from the accepted availability boundary in
# readiness-evidence/metrics-availability-lib.sh, which this file sources. This
# file never touches the accepted availability ledger.

[[ -n "${COHESIVE_LIB_LOADED:-}" ]] && return 0
COHESIVE_LIB_LOADED=1

cohesive_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=readiness-evidence/metrics-availability-lib.sh
source "$cohesive_lib_dir/../metrics-availability-lib.sh"

set -o pipefail

readonly COHESIVE_SCHEMA='lwrcohesive-scalar-bundle/v1'
readonly COHESIVE_FINDING='CI-LWR-001'
readonly COHESIVE_BOUNDARY='LWRACQ-20261014-v2#3.3'
readonly COHESIVE_FRAME_HEADER='LWRCOHESIVE-V1'

# --- D38 owner relay, preserved literally -----------------------------------
# Installed client launcher, installed interpreter (the accepted installer
# wrapper, NOT a guessed Python executable) and the dedicated profile root.
readonly COHESIVE_LAUNCHER='/home/dsaw/.local/bin/hermes'
readonly COHESIVE_ENTRYPOINT='/home/dsaw/.hermes/hermes-agent/.hermes/bin/hermes'
readonly COHESIVE_ENTRYPOINT_SHA256='1ef34d1b50357334a5193582060431605ad66f57f7d7ec1bb08b3d310481d2a9'
readonly COHESIVE_LAUNCHER_SHA256='3c3484d846fc5ac8975ab425198cdae292d9bf84da1e10be47e9bf00dcbf5fce'
readonly COHESIVE_HERMES_HOME='/home/dsaw/.hermes/profiles/local-implementer'
readonly COHESIVE_PROFILE_CONFIG_NAME='config.yaml'
# The one selected non-secret config leaf and its body-free getter argv.
readonly COHESIVE_GETTER_LEAF='model.context_length'
readonly COHESIVE_GETTER_VERB='config'
readonly COHESIVE_GETTER_SUBVERB='get'

# --- existing server/endpoint surface (reused verbatim) ----------------------
readonly COHESIVE_SSH_TARGET="$LWRACQ_SSH_TARGET"
readonly COHESIVE_METRICS_ENDPOINT="$LWRACQ_ENDPOINT"
readonly COHESIVE_HEALTH_ENDPOINT='http://127.0.0.1:8093/health'
readonly COHESIVE_PROPS_ENDPOINT='http://127.0.0.1:8093/props'

# Documented /props keys (pinned manual: default_generation_settings.n_ctx and
# total_slots). No aggregate is divided and no per-slot value is inferred.
readonly COHESIVE_PROPS_NCTX_KEY='n_ctx'
readonly COHESIVE_PROPS_SLOTS_KEY='total_slots'
# The frozen narrowing requires a canonical integer followed by a boundary, so
# a decimal, exponent or otherwise non-canonical spelling cannot be truncated
# into a value; the mapper re-anchors each match to the whole line.
#
# The boundary class excludes the decimal point AND both exponent markers: a
# bare [^0-9.] let "n_ctx": 2e5 match on its "2e", and the mapper then emitted
# props_n_ctx=2, silently truncating an exponent spelling into an accepted
# value. Any further numeric continuation therefore stops the field instead of
# being clipped, while a genuine integer followed by a delimiter or whitespace
# is still extracted.
readonly COHESIVE_PROPS_WIRE_PATTERN='"n_ctx"[[:space:]]*:[[:space:]]*[0-9]+[^0-9.eE]|"total_slots"[[:space:]]*:[[:space:]]*[0-9]+[^0-9.eE]'
readonly COHESIVE_PROPS_MAP_PROGRAM='s/^"n_ctx"[[:space:]]*:[[:space:]]*([0-9]+)[^0-9.eE]$/props_n_ctx=\1/p;s/^"total_slots"[[:space:]]*:[[:space:]]*([0-9]+)[^0-9.eE]$/props_total_slots=\1/p'

# A count or capacity fact is bounded well inside the shell's integer range, so
# a comparison can never overflow into a false verdict.
readonly COHESIVE_COUNT_RE='[0-9]{1,9}'
readonly COHESIVE_RESIDENCY_RE='[0-9]{1,18}'

# The accepted typed leaf value: a canonical positive integer, bounded well
# inside the shell's integer range so a comparison can never overflow. Decimal,
# exponent, boolean, mapping, leading-zero and oversized spellings are rejected
# rather than normalised or truncated.
readonly COHESIVE_CLIENT_RE='[1-9][0-9]{0,17}'

# --- reviewer-allowed bounded unprivileged inference-GPU idle leaves --------
readonly COHESIVE_GTIDLE_DIR='/sys/class/drm/card0/device/tile0/gt0/gtidle'
readonly COHESIVE_GTIDLE_STATUS_LEAF='/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_status'
readonly COHESIVE_GTIDLE_RESIDENCY_LEAF='/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_residency_ms'
# Documented residency unit, taken from the approved leaf name itself; the
# capture re-derives it from the resolved leaf so a renamed leaf stops.
readonly COHESIVE_RESIDENCY_UNIT='ms'
# One or two immediate samples. No interval and no idle threshold is invented.
readonly COHESIVE_GTIDLE_SAMPLES=2

# --- transport bounds -------------------------------------------------------
# Each of the two supervised operations reuses the accepted shape (3s connect,
# 10s request, zero curl retries, whole operation including cleanup <=30s).
readonly COHESIVE_CLIENT_LIMIT_S=30
readonly COHESIVE_SERVER_LIMIT_S=30
readonly COHESIVE_KILL_AFTER_S=1
readonly COHESIVE_TOTAL_LIMIT_S=60
readonly COHESIVE_DEFAULT_CLIENT_DEADLINE_S=29
readonly COHESIVE_DEFAULT_SERVER_DEADLINE_S=29
readonly COHESIVE_RETRIES=0

# Typed hold reasons (the complete vocabulary this preparation can emit).
readonly COHESIVE_REASONS='none banner unsafe_frame unsafe_label unsafe_value unsafe_name duplicate_fact missing_fact transport_failure deadline_exceeded curl_exit_nonzero filter_no_match filter_error health_unavailable gtidle_read_failed unknown_device unit_unknown counter_reset idle_state_changed capacity_mismatch client_getter_failed identity_mismatch identity_unknown identity_changed freshness_unknown availability_not_established availability_latch_modified latch_present'

# cohesive_reason_valid <reason>
cohesive_reason_valid() {
  [[ " $COHESIVE_REASONS " == *" $1 "* ]]
}

# cohesive_build_client_argv
#   Prints the exact, literal body-free getter invocation. The profile root is
#   set explicitly through HERMES_HOME and the accepted wrapper is used by its
#   absolute path: no mutable launcher, no copied resolver, no provisioning
#   subcommand, no --json/--raw/show/mapping/set form and no other argument.
cohesive_build_client_argv() {
  printf 'HERMES_HOME=%s %s %s %s %s' \
    "$COHESIVE_HERMES_HOME" "$COHESIVE_ENTRYPOINT" \
    "$COHESIVE_GETTER_VERB" "$COHESIVE_GETTER_SUBVERB" "$COHESIVE_GETTER_LEAF"
}

# cohesive_build_remote_script
#   Prints the exact remote script the driver hands to ssh. One ssh invocation
#   carries every server-side fact of the cohesive bundle from the same host.
#   The frame header is emitted first, so any banner or startup noise lands
#   before it and is rejected without being echoed. Every extraction is
#   anchored and server-side; only the documented scalars may leave the server.
#   All pipeline exits are emitted last, from PIPESTATUS, so curl's and the
#   filter's exits are both inspected, never the filter's alone.
cohesive_build_remote_script() {
  cat <<EOF
set -o pipefail
printf '%s\n' '${COHESIVE_FRAME_HEADER}'

# 1. Bounded unprivileged inference-GPU idle leaves: two immediate samples of
#    the two approved nodes only. No enumeration, privilege escalation, GPU
#    tool, daemon or write.
cohesive_read_leaf() {
  cohesive_leaf_value=''
  if read -r cohesive_leaf_value < "\$1"; then
    printf '%s' "\$cohesive_leaf_value"
    return 0
  fi
  [ -n "\$cohesive_leaf_value" ] || return 1
  printf '%s' "\$cohesive_leaf_value"
  return 0
}
if [ -d '${COHESIVE_GTIDLE_DIR}' ]; then
  printf 'gtidle_device=present\n'
else
  printf 'gtidle_device=absent\n'
fi
printf 'gtidle_unit=%s\n' "\$(printf '%s' '${COHESIVE_GTIDLE_RESIDENCY_LEAF}' | sed -n 's/.*_\([a-zA-Z][a-zA-Z0-9]*\)\$/\1/p')"
cohesive_read_exit=0
cohesive_status_1=''
cohesive_residency_1=''
cohesive_status_2=''
cohesive_residency_2=''
cohesive_status_1="\$(cohesive_read_leaf '${COHESIVE_GTIDLE_STATUS_LEAF}')" || cohesive_read_exit=1
cohesive_residency_1="\$(cohesive_read_leaf '${COHESIVE_GTIDLE_RESIDENCY_LEAF}')" || cohesive_read_exit=1
cohesive_status_2="\$(cohesive_read_leaf '${COHESIVE_GTIDLE_STATUS_LEAF}')" || cohesive_read_exit=1
cohesive_residency_2="\$(cohesive_read_leaf '${COHESIVE_GTIDLE_RESIDENCY_LEAF}')" || cohesive_read_exit=1
printf 'gtidle_status_1=%s\n' "\$cohesive_status_1"
printf 'gtidle_residency_1=%s\n' "\$cohesive_residency_1"
printf 'gtidle_status_2=%s\n' "\$cohesive_status_2"
printf 'gtidle_residency_2=%s\n' "\$cohesive_residency_2"

# 2. Existing health surface: the numeric HTTP status only. The response body
#    is discarded with -o /dev/null and never crosses the wire.
cohesive_health_status="\$(curl -sS --retry ${LWRACQ_CURL_RETRIES} --connect-timeout ${LWRACQ_CONNECT_TIMEOUT_S} --max-time ${LWRACQ_REQUEST_TIMEOUT_S} -o /dev/null -w '%{http_code}' '${COHESIVE_HEALTH_ENDPOINT}')"
cohesive_health_exit=\$?
printf 'health_status=%s\n' "\$cohesive_health_status"

# 3. Server supported per-slot capacity, read from the server's own scalar
#    /props fields. The narrow anchored pattern keeps two documented keys and
#    drops model paths, slot stores, every other key and all surrounding body;
#    the mapper re-anchors each match, so a non-canonical spelling is never
#    truncated into a value. All three pipeline exits are inspected.
curl -fsS --retry ${LWRACQ_CURL_RETRIES} --connect-timeout ${LWRACQ_CONNECT_TIMEOUT_S} --max-time ${LWRACQ_REQUEST_TIMEOUT_S} '${COHESIVE_PROPS_ENDPOINT}' 2>/dev/null | grep -oE '${COHESIVE_PROPS_WIRE_PATTERN}' | sed -E -n -e '${COHESIVE_PROPS_MAP_PROGRAM}'
cohesive_props_pipe=("\${PIPESTATUS[@]}")
cohesive_props_curl_exit="\${cohesive_props_pipe[0]}"
cohesive_props_filter_exit="\${cohesive_props_pipe[1]}"
cohesive_props_map_exit="\${cohesive_props_pipe[2]}"

# 4. Same-endpoint occupancy gauges, through the accepted anchored narrowing.
curl -fsS --retry ${LWRACQ_CURL_RETRIES} --connect-timeout ${LWRACQ_CONNECT_TIMEOUT_S} --max-time ${LWRACQ_REQUEST_TIMEOUT_S} '${LWRACQ_ENDPOINT}' 2>/dev/null | grep -E '${LWRACQ_WIRE_PATTERN}'
cohesive_metrics_pipe=("\${PIPESTATUS[@]}")
cohesive_metrics_curl_exit="\${cohesive_metrics_pipe[0]}"
cohesive_metrics_filter_exit="\${cohesive_metrics_pipe[1]}"

# 5. Every exit of every pipeline, last, so the validator inspects all of them.
printf 'gtidle_read_exit=%s\n' "\$cohesive_read_exit"
printf 'health_curl_exit=%s\n' "\$cohesive_health_exit"
printf 'props_curl_exit=%s\n' "\$cohesive_props_curl_exit"
printf 'props_filter_exit=%s\n' "\$cohesive_props_filter_exit"
printf 'props_map_exit=%s\n' "\$cohesive_props_map_exit"
printf 'metrics_curl_exit=%s\n' "\$cohesive_metrics_curl_exit"
printf 'metrics_filter_exit=%s\n' "\$cohesive_metrics_filter_exit"
EOF
}

# cohesive_is_gauge_line <line>
cohesive_is_gauge_line() {
  local line="$1"
  [[ "$line" =~ ^${LWRACQ_GAUGE_PROCESSING}[[:space:]]+${LWRACQ_INTEGER_RE}$ ]] ||
    [[ "$line" =~ ^${LWRACQ_GAUGE_DEFERRED}[[:space:]]+${LWRACQ_INTEGER_RE}$ ]]
}

# cohesive_scalar_key_known <key>
cohesive_scalar_key_known() {
  case "$1" in
    gtidle_device | gtidle_unit | gtidle_status_1 | gtidle_residency_1 | \
      gtidle_status_2 | gtidle_residency_2 | gtidle_read_exit | health_status | \
      health_curl_exit | props_n_ctx | props_total_slots | props_curl_exit | \
      props_filter_exit | props_map_exit | metrics_curl_exit | metrics_filter_exit) return 0 ;;
    *) return 1 ;;
  esac
}

# cohesive_scalar_value_ok <key> <value>
#   The four gtidle value keys accept an empty value here so that a genuine read
#   failure is reported as gtidle_read_failed by the exit pass rather than being
#   mislabelled; emptiness is still rejected once the reads are known to have
#   succeeded.
cohesive_scalar_value_ok() {
  local key="$1" value="$2"
  case "$key" in
    gtidle_device) [[ "$value" == 'present' || "$value" == 'absent' ]] ;;
    gtidle_unit) [[ "$value" =~ ^[a-zA-Z][a-zA-Z0-9]{0,7}$ ]] ;;
    gtidle_status_1 | gtidle_status_2) [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] ;;
    gtidle_residency_1 | gtidle_residency_2) [[ -z "$value" || "$value" =~ ^${COHESIVE_RESIDENCY_RE}$ ]] ;;
    props_n_ctx | props_total_slots) [[ "$value" =~ ^${COHESIVE_COUNT_RE}$ ]] ;;
    gtidle_read_exit | health_curl_exit | props_curl_exit | props_filter_exit | \
      props_map_exit | metrics_curl_exit | metrics_filter_exit) [[ "$value" =~ ^[0-9]{1,4}$ ]] ;;
    health_status) [[ "$value" =~ ^[0-9]{3}$ ]] ;;
    *) return 1 ;;
  esac
}

# cohesive_validate_client_frame <frame-file>
#   Judges the private stdout of the body-free getter.
#     COH_STATUS  CAPTURED | HOLD
#     COH_REASON  none | missing_fact | unsafe_frame | unsafe_label | unsafe_value
#     COH_CLIENT_VALUE
#   It never prints, returns or writes any frame content. Always returns 0; the
#   caller decides the process exit status from COH_STATUS.
cohesive_validate_client_frame() {
  local frame="$1"
  local -a lines=()
  local line trimmed

  COH_STATUS='HOLD'
  COH_REASON='unsafe_frame'
  COH_FACT='client'
  COH_CLIENT_VALUE=''

  [[ -r "$frame" ]] || return 0
  mapfile -t lines <"$frame"
  ((${#lines[@]})) || { COH_REASON='missing_fact'; return 0; }

  # A selected-leaf getter emits exactly one line holding the value.
  ((${#lines[@]} == 1)) || { COH_REASON='unsafe_frame'; return 0; }
  line="${lines[0]}"
  [[ -n "$line" ]] || { COH_REASON='missing_fact'; return 0; }

  trimmed="${line#"${line%%[![:space:]]*}"}"
  trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

  # A mapping, object or key=value form is not a selected scalar leaf.
  case "$trimmed" in
    *'{'* | *'}'* | *'['* | *']'* | *'"'* | *'='*) COH_REASON='unsafe_label'; return 0 ;;
  esac
  # Booleans, nulls and raw diagnostics are rejected, never normalised.
  case "$trimmed" in
    true | false | null | none | NaN | nan | inf | Infinity | infinity)
      COH_REASON='unsafe_value'
      return 0
      ;;
  esac
  [[ "$trimmed" =~ ^${COHESIVE_CLIENT_RE}$ ]] || { COH_REASON='unsafe_value'; return 0; }
  # v1 #3.1 rejects nonpositive values instead of substituting a default.
  ((trimmed > 0)) || { COH_REASON='unsafe_value'; return 0; }

  COH_STATUS='CAPTURED'
  COH_REASON='none'
  COH_CLIENT_VALUE="$trimmed"
  return 0
}

# cohesive_validate_server_frame <frame-file>
#   Judges the one server frame and sets every typed server fact:
#     COH_STATUS  CAPTURED | HOLD
#     COH_REASON  none | banner | unsafe_frame | unsafe_label | unsafe_value |
#                 unsafe_name | duplicate_fact | missing_fact |
#                 transport_failure | curl_exit_nonzero | filter_no_match |
#                 filter_error | health_unavailable | gtidle_read_failed |
#                 unknown_device | unit_unknown | counter_reset | idle_state_changed
#     COH_FACT     client | server
#     COH_GTIDLE_*, COH_HEALTH_*, COH_PROPS_*, COH_METRICS_*, COH_PROC, COH_DEFER
#   It never prints, returns or writes any frame content. Always returns 0.
cohesive_validate_server_frame() {
  local frame="$1"
  local -a lines=()
  local i line key value seen=' '
  local header_index=-1
  local gtidle_device='' gtidle_unit='' status_1='' residency_1='' status_2='' residency_2=''
  local gtidle_read_exit='' health_status='' health_curl_exit=''
  local props_n_ctx='' props_total_slots='' props_curl_exit='' props_filter_exit=''
  local props_map_exit=''
  local metrics_curl_exit='' metrics_filter_exit=''
  local proc='' defer='' proc_seen=0 defer_seen=0

  COH_STATUS='HOLD'
  COH_REASON='unsafe_frame'
  COH_FACT='server'
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

  [[ -r "$frame" ]] || return 0
  mapfile -t lines <"$frame"
  ((${#lines[@]})) || return 0

  # Pass 1 - structure: exactly one header, and nothing may precede it.
  for ((i = 0; i < ${#lines[@]}; i++)); do
    if [[ "${lines[i]}" == "$COHESIVE_FRAME_HEADER" ]]; then
      header_index=$i
      break
    fi
  done
  if ((header_index < 0)); then
    for line in "${lines[@]}"; do
      [[ -n "$line" ]] && COH_REASON='banner'
    done
    return 0
  fi
  ((header_index > 0)) && { COH_REASON='banner'; return 0; }

  # Pass 2 - classify every remaining line; a second frame means more than one
  # remote read was serviced. Unknown or malformed content is rejected, never
  # echoed or sanitised.
  for ((i = 1; i < ${#lines[@]}; i++)); do
    line="${lines[i]}"
    if [[ "$line" == "$COHESIVE_FRAME_HEADER" ]]; then
      COH_REASON='unsafe_frame'
      return 0
    fi
    if [[ -z "$line" ]]; then
      COH_REASON='unsafe_frame'
      return 0
    fi
    case "$line" in
      *'{'* | *'}'* | *'['* | *']'* | *'"'*) COH_REASON='unsafe_label'; return 0 ;;
    esac
    if cohesive_is_gauge_line "$line"; then
      if [[ "$line" == "${LWRACQ_GAUGE_PROCESSING} "* ]]; then
        ((proc_seen)) && { COH_REASON='duplicate_fact'; return 0; }
        proc_seen=1
        proc="${line#"${LWRACQ_GAUGE_PROCESSING}"}"
        proc="${proc//[[:space:]]/}"
      else
        ((defer_seen)) && { COH_REASON='duplicate_fact'; return 0; }
        defer_seen=1
        defer="${line#"${LWRACQ_GAUGE_DEFERRED}"}"
        defer="${defer//[[:space:]]/}"
      fi
      continue
    fi
    case "$line" in
      "${LWRACQ_GAUGE_PROCESSING}"* | "${LWRACQ_GAUGE_DEFERRED}"*) COH_REASON='unsafe_value'; return 0 ;;
    esac
    if [[ "$line" =~ ^([a-z][a-z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      cohesive_scalar_key_known "$key" || { COH_REASON='unsafe_name'; return 0; }
      cohesive_scalar_value_ok "$key" "$value" || { COH_REASON='unsafe_value'; return 0; }
      [[ "$seen" == *" $key "* ]] && { COH_REASON='duplicate_fact'; return 0; }
      seen="$seen$key "
      case "$key" in
        gtidle_device) gtidle_device="$value" ;;
        gtidle_unit) gtidle_unit="$value" ;;
        gtidle_status_1) status_1="$value" ;;
        gtidle_residency_1) residency_1="$value" ;;
        gtidle_status_2) status_2="$value" ;;
        gtidle_residency_2) residency_2="$value" ;;
        gtidle_read_exit) gtidle_read_exit="$value" ;;
        health_status) health_status="$value" ;;
        health_curl_exit) health_curl_exit="$value" ;;
        props_n_ctx) props_n_ctx="$value" ;;
        props_total_slots) props_total_slots="$value" ;;
        props_curl_exit) props_curl_exit="$value" ;;
        props_filter_exit) props_filter_exit="$value" ;;
        props_map_exit) props_map_exit="$value" ;;
        metrics_curl_exit) metrics_curl_exit="$value" ;;
        metrics_filter_exit) metrics_filter_exit="$value" ;;
      esac
      continue
    fi
    COH_REASON='unsafe_name'
    return 0
  done

  # Pass 3 - every pipeline exit, not the filter's alone. A key that is absent
  # entirely is reported by the presence pass below rather than guessed here.
  if [[ "$seen" == *" gtidle_read_exit "* ]] && ((gtidle_read_exit != 0)); then
    COH_REASON='gtidle_read_failed'
    return 0
  fi
  if [[ "$seen" == *" health_curl_exit "* ]] && ((health_curl_exit != 0)); then
    COH_REASON='transport_failure'
    return 0
  fi
  if [[ "$seen" == *" props_curl_exit "* ]] && ((props_curl_exit != 0)); then
    COH_REASON='transport_failure'
    return 0
  fi
  if [[ "$seen" == *" metrics_curl_exit "* ]] && ((metrics_curl_exit != 0)); then
    COH_REASON='curl_exit_nonzero'
    return 0
  fi
  if [[ "$seen" == *" props_filter_exit "* ]]; then
    ((props_filter_exit == 1)) && { COH_REASON='filter_no_match'; return 0; }
    ((props_filter_exit > 1)) && { COH_REASON='filter_error'; return 0; }
  fi
  if [[ "$seen" == *" props_map_exit "* ]] && ((props_map_exit != 0)); then
    COH_REASON='filter_error'
    return 0
  fi
  if [[ "$seen" == *" metrics_filter_exit "* ]]; then
    ((metrics_filter_exit == 1)) && { COH_REASON='filter_no_match'; return 0; }
    ((metrics_filter_exit > 1)) && { COH_REASON='filter_error'; return 0; }
  fi

  # Pass 4 - presence of every required fact, and of both gauges.
  for key in gtidle_device gtidle_unit gtidle_status_1 gtidle_residency_1 \
    gtidle_status_2 gtidle_residency_2 gtidle_read_exit health_status \
    health_curl_exit props_n_ctx props_total_slots props_curl_exit \
    props_filter_exit props_map_exit metrics_curl_exit metrics_filter_exit; do
    [[ "$seen" == *" $key "* ]] || { COH_REASON='missing_fact'; return 0; }
  done
  ((proc_seen && defer_seen)) || { COH_REASON='missing_fact'; return 0; }

  COH_GTIDLE_DEVICE="$gtidle_device"
  COH_GTIDLE_UNIT="$gtidle_unit"
  COH_GTIDLE_STATUS_1="$status_1"
  COH_GTIDLE_RESIDENCY_1="$residency_1"
  COH_GTIDLE_STATUS_2="$status_2"
  COH_GTIDLE_RESIDENCY_2="$residency_2"
  COH_GTIDLE_READ_EXIT="$gtidle_read_exit"
  COH_HEALTH_STATUS="$health_status"
  COH_HEALTH_CURL_EXIT="$health_curl_exit"
  COH_PROPS_NCTX="$props_n_ctx"
  COH_PROPS_SLOTS="$props_total_slots"
  COH_PROPS_CURL_EXIT="$props_curl_exit"
  COH_PROPS_FILTER_EXIT="$props_filter_exit"
  COH_PROPS_MAP_EXIT="$props_map_exit"
  COH_METRICS_CURL_EXIT="$metrics_curl_exit"
  COH_METRICS_FILTER_EXIT="$metrics_filter_exit"
  COH_PROC="$proc"
  COH_DEFER="$defer"

  # Pass 5 - typed facts. Nothing here is promoted: a state observation is not
  # an idle window, and no aggregate is ever divided into a per-slot value.
  ((health_status == 200)) || { COH_REASON='health_unavailable'; return 0; }
  [[ -n "$status_1" && -n "$residency_1" && -n "$status_2" && -n "$residency_2" ]] ||
    { COH_REASON='unsafe_value'; return 0; }
  [[ "$gtidle_device" == 'present' ]] || { COH_REASON='unknown_device'; return 0; }
  [[ "$gtidle_unit" == "$COHESIVE_RESIDENCY_UNIT" ]] || { COH_REASON='unit_unknown'; return 0; }
  ((props_n_ctx > 0)) || { COH_REASON='unsafe_value'; return 0; }
  ((props_total_slots > 0)) || { COH_REASON='unsafe_value'; return 0; }
  [[ "$status_1" == "$status_2" ]] || { COH_REASON='idle_state_changed'; return 0; }
  ((residency_2 >= residency_1)) || { COH_REASON='counter_reset'; return 0; }

  COH_STATUS='CAPTURED'
  COH_REASON='none'
  return 0
}

# cohesive_capacity_relation <client-value> <server-per-slot-value>
#   Prints equal | mismatch. It compares strengths honestly: the client value is
#   configured intent only, and the comparison never divides or infers a value.
cohesive_capacity_relation() {
  if [[ "$1" == "$2" ]]; then
    printf 'equal'
  else
    printf 'mismatch'
  fi
}

# cohesive_json_str_or_null <value>
cohesive_json_str_or_null() {
  if [[ -n "${1:-}" ]]; then
    printf '"%s"' "$1"
  else
    printf 'null'
  fi
}

# cohesive_json_int_or_null <value>
cohesive_json_int_or_null() {
  if [[ "${1:-}" =~ ^[0-9]{1,18}$ ]]; then
    printf '%s' "$1"
  else
    printf 'null'
  fi
}
