#!/usr/bin/env bash

set -euo pipefail

: "${JQ_BIN:=jq}"
: "${DATE_BIN:=date}"
: "${MKTEMP_BIN:=mktemp}"
: "${MV_BIN:=mv}"
: "${CHMOD_BIN:=chmod}"
: "${RM_BIN:=rm}"

status_file=""
attempt_id=""
state=""
failure_class=""
reason=""
message=""
retryable=""
operator_action_required=""
repository_bytes=""
limit_bytes=""

while (( $# > 0 )); do
  case "$1" in
    --status-file) status_file="${2:?--status-file requires a value}"; shift 2 ;;
    --attempt-id) attempt_id="${2:?--attempt-id requires a value}"; shift 2 ;;
    --state) state="${2:?--state requires a value}"; shift 2 ;;
    --failure-class) failure_class="${2:?--failure-class requires a value}"; shift 2 ;;
    --reason) reason="${2:?--reason requires a value}"; shift 2 ;;
    --message) message="${2:?--message requires a value}"; shift 2 ;;
    --retryable) retryable="${2:?--retryable requires a value}"; shift 2 ;;
    --operator-action-required) operator_action_required="${2:?--operator-action-required requires a value}"; shift 2 ;;
    --repository-bytes) repository_bytes="${2:?--repository-bytes requires a value}"; shift 2 ;;
    --limit-bytes) limit_bytes="${2:?--limit-bytes requires a value}"; shift 2 ;;
    *) echo "Unknown MEGA status-event argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$status_file" ]] || { echo "Missing MEGA status file" >&2; exit 64; }
[[ "$attempt_id" =~ ^[A-Za-z0-9._:-]{1,128}$ ]] || { echo "Invalid MEGA attempt ID" >&2; exit 64; }
case "$state" in
  running|success|blocked|retrying|failed) ;;
  *) echo "Invalid MEGA sync state" >&2; exit 64 ;;
esac
case "$failure_class" in
  none|capacity|transient|safety|repository|remote) ;;
  *) echo "Invalid MEGA failure class" >&2; exit 64 ;;
esac
[[ "$reason" =~ ^[a-z][a-z0-9_]{1,63}$ ]] || { echo "Invalid MEGA reason code" >&2; exit 64; }
[[ -n "$message" && ${#message} -le 512 && "$message" != *$'\n'* && "$message" != *$'\r'* ]] || {
  echo "Invalid MEGA status message" >&2
  exit 64
}
case "$retryable" in true|false) ;; *) echo "Invalid retryable value" >&2; exit 64 ;; esac
case "$operator_action_required" in true|false) ;; *) echo "Invalid operator-action value" >&2; exit 64 ;; esac
[[ "$repository_bytes" =~ ^[0-9]+$ && "$limit_bytes" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid MEGA status byte count" >&2
  exit 64
}

status_dir="$(dirname "$status_file")"
status_name="$(basename "$status_file")"
[[ -d "$status_dir" ]] || { echo "MEGA status directory does not exist" >&2; exit 73; }

timestamp="$($DATE_BIN --utc --iso-8601=seconds)"
event_json="$($JQ_BIN -nc \
  --arg event mega_kopia_sync_state \
  --arg timestamp "$timestamp" \
  --arg attemptId "$attempt_id" \
  --arg state "$state" \
  --arg failureClass "$failure_class" \
  --arg reason "$reason" \
  --arg message "$message" \
  --argjson retryable "$retryable" \
  --argjson operatorActionRequired "$operator_action_required" \
  --argjson repositoryBytes "$repository_bytes" \
  --argjson limitBytes "$limit_bytes" \
  '{schemaVersion:1,event:$event,timestamp:$timestamp,attemptId:$attemptId,state:$state,failureClass:$failureClass,reason:$reason,message:$message,retryable:$retryable,operatorActionRequired:$operatorActionRequired,repositoryBytes:$repositoryBytes,limitBytes:$limitBytes}')"

umask 0077
status_tmp="$($MKTEMP_BIN "$status_dir/.${status_name}.XXXXXX")"
cleanup() {
  [[ -z "${status_tmp:-}" ]] || "$RM_BIN" -f -- "$status_tmp"
}
trap cleanup EXIT
printf '%s\n' "$event_json" > "$status_tmp"
"$CHMOD_BIN" 0600 "$status_tmp"
"$MV_BIN" -f -- "$status_tmp" "$status_file"
status_tmp=""
printf '%s\n' "$event_json"
