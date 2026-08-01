#!/usr/bin/env bash

set -euo pipefail

: "${RCLONE_BIN:=rclone}"
: "${JQ_BIN:=jq}"
: "${DU_BIN:=du}"
: "${DATE_BIN:=date}"
: "${MKTEMP_BIN:=mktemp}"
: "${MV_BIN:=mv}"
: "${CHMOD_BIN:=chmod}"
: "${RM_BIN:=rm}"

config_file=""
remote=""
source_path=""
status_file=""
alert_state_file=""
sync_status_file=""
warn_percent=""
critical_percent=""
limit_bytes=""
cooldown_seconds=""

while (( $# > 0 )); do
  case "$1" in
    --config) config_file="${2:?--config requires a value}"; shift 2 ;;
    --remote) remote="${2:?--remote requires a value}"; shift 2 ;;
    --source) source_path="${2:?--source requires a value}"; shift 2 ;;
    --status-file) status_file="${2:?--status-file requires a value}"; shift 2 ;;
    --alert-state-file) alert_state_file="${2:?--alert-state-file requires a value}"; shift 2 ;;
    --sync-status-file) sync_status_file="${2:?--sync-status-file requires a value}"; shift 2 ;;
    --warn-percent) warn_percent="${2:?--warn-percent requires a value}"; shift 2 ;;
    --critical-percent) critical_percent="${2:?--critical-percent requires a value}"; shift 2 ;;
    --limit-bytes) limit_bytes="${2:?--limit-bytes requires a value}"; shift 2 ;;
    --cooldown-seconds) cooldown_seconds="${2:?--cooldown-seconds requires a value}"; shift 2 ;;
    *) echo "Unknown MEGA capacity argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$config_file" && -n "$remote" && -n "$source_path" ]] || {
  echo "Missing MEGA capacity endpoint argument" >&2
  exit 64
}
[[ -n "$status_file" && -n "$alert_state_file" && -n "$sync_status_file" ]] || {
  echo "Missing MEGA capacity state path" >&2
  exit 64
}
[[ "$warn_percent" =~ ^[1-9][0-9]*$ \
  && "$critical_percent" =~ ^[1-9][0-9]*$ \
  && "$limit_bytes" =~ ^[1-9][0-9]*$ \
  && "$cooldown_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid MEGA capacity threshold" >&2
  exit 64
}
(( warn_percent < critical_percent && critical_percent <= 100 )) || {
  echo "MEGA capacity thresholds must be ordered and no greater than 100" >&2
  exit 64
}

status_dir="$(dirname "$status_file")"
status_name="$(basename "$status_file")"
alert_state_dir="$(dirname "$alert_state_file")"
alert_state_name="$(basename "$alert_state_file")"
[[ -d "$status_dir" && -d "$alert_state_dir" ]] || {
  echo "MEGA capacity state directory does not exist" >&2
  exit 73
}

timestamp="$($DATE_BIN --utc --iso-8601=seconds)"
now_epoch="$($DATE_BIN +%s)"
[[ "$now_epoch" =~ ^[0-9]+$ ]] || {
  echo "Could not determine the current time for MEGA capacity alerting" >&2
  exit 70
}

repository_bytes=0
repository_percent=0
remote_total_bytes=0
remote_used_bytes=0
remote_free_bytes=0
remote_used_percent=0
state=failed
failure_class=repository
reason=local_repository_size_unavailable
message="Could not measure the local Kopia repository."
operator_action_required=true
last_sync_reason=none

write_atomic() {
  local destination="$1"
  local destination_dir="$2"
  local destination_name="$3"
  local contents="$4"
  local temp_file
  umask 0077
  temp_file="$($MKTEMP_BIN "$destination_dir/.${destination_name}.XXXXXX")"
  if ! printf '%s\n' "$contents" > "$temp_file" \
    || ! "$CHMOD_BIN" 0600 "$temp_file" \
    || ! "$MV_BIN" -f -- "$temp_file" "$destination"; then
    "$RM_BIN" -f -- "$temp_file"
    return 73
  fi
}

classify() {
  local repository_output quota quota_values

  if repository_output="$($DU_BIN --summarize --bytes -- "$source_path")"; then
    repository_bytes="${repository_output%%[[:space:]]*}"
    if [[ ! "$repository_bytes" =~ ^[0-9]+$ ]]; then
      repository_bytes=0
    else
      repository_percent=$(( repository_bytes * 100 / limit_bytes ))
      state=failed
      failure_class=remote
      reason=remote_quota_unavailable
      message="Could not query the MEGA storage quota."
    fi
  fi

  [[ "$reason" != local_repository_size_unavailable ]] || return 0

  if ! quota="$($RCLONE_BIN about --config "$config_file" --json "$remote")"; then
    return 0
  fi
  if ! quota_values="$($JQ_BIN -er '
    [.total, .used, (.free // (.total - .used))]
    | select(length == 3 and all(.[]; type == "number" and . >= 0 and floor == .))
    | @tsv
  ' <<<"$quota")"; then
    reason=remote_quota_invalid
    message="MEGA returned an invalid storage quota."
    return 0
  fi
  read -r remote_total_bytes remote_used_bytes remote_free_bytes <<<"$quota_values"
  if [[ ! "$remote_total_bytes" =~ ^[1-9][0-9]*$ \
    || ! "$remote_used_bytes" =~ ^[0-9]+$ \
    || ! "$remote_free_bytes" =~ ^[0-9]+$ \
    || "$remote_used_bytes" -gt "$remote_total_bytes" ]]; then
    reason=remote_quota_invalid
    message="MEGA returned an unusable storage quota."
    return 0
  fi

  remote_used_percent=$(( remote_used_bytes * 100 / remote_total_bytes ))
  failure_class=capacity
  operator_action_required=false
  if (( repository_bytes >= limit_bytes )); then
    state=blocked
    reason=local_repository_limit
    message="The local Kopia repository reached its offsite safety ceiling."
    operator_action_required=true
  elif (( repository_percent >= critical_percent || remote_used_percent >= critical_percent )); then
    state=critical
    reason=capacity_critical
    message="MEGA or the local Kopia repository reached the critical capacity threshold."
    operator_action_required=true
  elif (( repository_percent >= warn_percent || remote_used_percent >= warn_percent )); then
    state=warning
    reason=capacity_warning
    message="MEGA or the local Kopia repository reached the capacity warning threshold."
  else
    state=ok
    failure_class=none
    reason=capacity_ok
    message="MEGA and the local Kopia repository are within their capacity budgets."
  fi
}

classify

if [[ -f "$sync_status_file" ]]; then
  if sync_status_values="$($JQ_BIN -er '
    select(
      .schemaVersion == 1
      and .event == "mega_kopia_sync_state"
      and (
        ((.state == "running" or .state == "success") and .failureClass == "none")
        or (.state == "blocked" and .failureClass == "capacity")
        or (.state == "retrying" and .failureClass == "transient")
        or (
          .state == "failed"
          and (
            .failureClass == "safety"
            or .failureClass == "repository"
            or .failureClass == "remote"
          )
        )
      )
      and (.reason | type == "string" and test("^[a-z][a-z0-9_]{1,63}$"))
    )
    | [.state, .failureClass, .reason]
    | @tsv
  ' "$sync_status_file")"; then
    read -r last_sync_state last_sync_class last_sync_reason <<<"$sync_status_values"
    if [[ "$state" != failed && "$last_sync_state" == blocked && "$last_sync_class" == capacity ]]; then
      state=blocked
      failure_class=capacity
      reason=offsite_sync_capacity_blocked
      message="The latest offsite mirror attempt was blocked by its projected capacity check."
      operator_action_required=true
    fi
  else
    state=failed
    failure_class=repository
    reason=sync_status_invalid
    message="The persisted MEGA sync status is invalid."
    operator_action_required=true
    last_sync_reason=invalid
  fi
fi

alert_required=false
alert_suppressed=false
case "$state" in
  ok|warning)
    "$RM_BIN" -f -- "$alert_state_file"
    ;;
  critical|blocked|failed)
    previous_alert=0
    if [[ -f "$alert_state_file" ]]; then
      read -r previous_alert < "$alert_state_file" || previous_alert=0
      [[ "$previous_alert" =~ ^[0-9]+$ ]] || previous_alert=0
    fi
    if (( previous_alert > 0 \
      && (now_epoch < previous_alert || now_epoch - previous_alert < cooldown_seconds) )); then
      alert_suppressed=true
    else
      alert_required=true
      write_atomic "$alert_state_file" "$alert_state_dir" "$alert_state_name" "$now_epoch"
    fi
    ;;
esac

event_json="$($JQ_BIN -nc \
  --arg event mega_backup_capacity \
  --arg timestamp "$timestamp" \
  --arg state "$state" \
  --arg failureClass "$failure_class" \
  --arg reason "$reason" \
  --arg message "$message" \
  --argjson operatorActionRequired "$operator_action_required" \
  --argjson alertRequired "$alert_required" \
  --argjson alertSuppressed "$alert_suppressed" \
  --argjson repositoryBytes "$repository_bytes" \
  --argjson repositoryPercent "$repository_percent" \
  --argjson limitBytes "$limit_bytes" \
  --argjson remoteTotalBytes "$remote_total_bytes" \
  --argjson remoteUsedBytes "$remote_used_bytes" \
  --argjson remoteFreeBytes "$remote_free_bytes" \
  --argjson remoteUsedPercent "$remote_used_percent" \
  --arg lastSyncReason "$last_sync_reason" \
  '{schemaVersion:1,event:$event,timestamp:$timestamp,state:$state,failureClass:$failureClass,reason:$reason,message:$message,operatorActionRequired:$operatorActionRequired,alertRequired:$alertRequired,alertSuppressed:$alertSuppressed,repositoryBytes:$repositoryBytes,repositoryPercent:$repositoryPercent,limitBytes:$limitBytes,remoteTotalBytes:$remoteTotalBytes,remoteUsedBytes:$remoteUsedBytes,remoteFreeBytes:$remoteFreeBytes,remoteUsedPercent:$remoteUsedPercent,lastSyncReason:$lastSyncReason}')"

write_atomic "$status_file" "$status_dir" "$status_name" "$event_json"
printf '%s\n' "$event_json"
[[ "$alert_required" == false ]]
