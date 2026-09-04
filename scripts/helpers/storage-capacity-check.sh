#!/usr/bin/env bash

set -euo pipefail

: "${DF_BIN:=df}"
: "${JQ_BIN:=jq}"
: "${DATE_BIN:=date}"
: "${MKTEMP_BIN:=mktemp}"
: "${MV_BIN:=mv}"
: "${CHMOD_BIN:=chmod}"
: "${RM_BIN:=rm}"

status_file=""
alert_state_file=""
warn_percent=""
critical_percent=""
cooldown_seconds=""
monitor_paths=()

while (( $# > 0 )); do
  case "$1" in
    --status-file) status_file="${2:?--status-file requires a value}"; shift 2 ;;
    --alert-state-file) alert_state_file="${2:?--alert-state-file requires a value}"; shift 2 ;;
    --monitor-path)
      [[ -n "${2:-}" && "${2:-}" != --* ]] || {
        echo "--monitor-path requires a filesystem path" >&2
        exit 64
      }
      monitor_paths+=("$2")
      shift 2
      ;;
    --warn-percent) warn_percent="${2:?--warn-percent requires a value}"; shift 2 ;;
    --critical-percent) critical_percent="${2:?--critical-percent requires a value}"; shift 2 ;;
    --cooldown-seconds) cooldown_seconds="${2:?--cooldown-seconds requires a value}"; shift 2 ;;
    *) echo "Unknown storage capacity argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$status_file" && -n "$alert_state_file" ]] || {
  echo "Missing storage capacity state path" >&2
  exit 64
}
(( ${#monitor_paths[@]} > 0 )) || {
  echo "At least one --monitor-path is required" >&2
  exit 64
}
[[ "$warn_percent" =~ ^[1-9][0-9]*$ \
  && "$critical_percent" =~ ^[1-9][0-9]*$ \
  && "$cooldown_seconds" =~ ^[1-9][0-9]*$ ]] || {
  echo "Invalid storage capacity threshold" >&2
  exit 64
}
(( warn_percent < critical_percent && critical_percent <= 100 )) || {
  echo "Storage capacity thresholds must be ordered and no greater than 100" >&2
  exit 64
}

status_dir="$(dirname "$status_file")"
status_name="$(basename "$status_file")"
alert_state_dir="$(dirname "$alert_state_file")"
alert_state_name="$(basename "$alert_state_file")"
[[ -d "$status_dir" && -d "$alert_state_dir" ]] || {
  echo "Storage capacity state directory does not exist" >&2
  exit 73
}

timestamp="$($DATE_BIN --utc --iso-8601=seconds)"
now_epoch="$($DATE_BIN +%s)"
[[ "$now_epoch" =~ ^[0-9]+$ ]] || {
  echo "Could not determine the current time for storage capacity alerting" >&2
  exit 70
}

paths_json="[]"
skipped_duplicate_paths="[]"
max_used_percent=0
state=ok
failure_class=none
reason=capacity_ok
message="All watched filesystems are within their capacity budgets."
operator_action_required=false

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

# Measure every monitored path once per backing device. Deduplicating by
# device keeps duplicate mountpoints (for example /persist on the root
# filesystem) from double-reporting the same filesystem usage.
declare -A seen_devices=()
for path in "${monitor_paths[@]}"; do
  if ! df_line="$($DF_BIN -P -B1 -- "$path" 2>/dev/null | awk 'NR == 2 { print $1, $2, $3, $4 }')"; then
    state=failed
    failure_class=measurement
    reason=path_unavailable
    message="A watched filesystem could not be measured: $path"
    operator_action_required=true
    continue
  fi
  read -r device total used available <<<"$df_line"
  if [[ ! "$total" =~ ^[1-9][0-9]*$ \
    || ! "$used" =~ ^[0-9]+$ \
    || ! "$available" =~ ^[0-9]+$ ]]; then
    state=failed
    failure_class=measurement
    reason=df_output_invalid
    message="Could not parse df output for a watched filesystem: $path"
    operator_action_required=true
    continue
  fi

  if [[ -n "${seen_devices[$device]:-}" ]]; then
    skipped_duplicate_paths="$($JQ_BIN -n \
      --arg path "$path" \
      --argjson list "$skipped_duplicate_paths" \
      '$list + [$path]')"
    continue
  fi
  seen_devices["$device"]=1

  row="$($JQ_BIN -nc \
    --arg path "$path" \
    --arg device "$device" \
    --argjson totalBytes "$total" \
    --argjson usedBytes "$used" \
    --argjson availableBytes "$available" \
    '{path:$path,device:$device,totalBytes:$totalBytes,usedBytes:$usedBytes,availableBytes:$availableBytes,usedPercent:(($usedBytes * 100 / $totalBytes) | floor)}')"
  paths_json="$($JQ_BIN -n --argjson list "$paths_json" --argjson row "$row" '$list + [$row]')"

  row_percent="$($JQ_BIN -r '.usedPercent' <<<"$row")"
  (( row_percent > max_used_percent )) && max_used_percent="$row_percent"
done

if [[ "$state" != failed ]]; then
  if (( max_used_percent >= critical_percent )); then
    state=critical
    failure_class=capacity
    reason=capacity_critical
    message="A watched filesystem reached the critical capacity threshold."
    operator_action_required=true
  elif (( max_used_percent >= warn_percent )); then
    state=warning
    failure_class=capacity
    reason=capacity_warning
    message="A watched filesystem reached the capacity warning threshold."
  fi
fi

alert_required=false
alert_suppressed=false
case "$state" in
  ok|warning)
    "$RM_BIN" -f -- "$alert_state_file"
    ;;
  critical|failed)
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
  --arg event storage_capacity \
  --arg timestamp "$timestamp" \
  --arg state "$state" \
  --arg failureClass "$failure_class" \
  --arg reason "$reason" \
  --arg message "$message" \
  --argjson operatorActionRequired "$operator_action_required" \
  --argjson alertRequired "$alert_required" \
  --argjson alertSuppressed "$alert_suppressed" \
  --argjson warnPercent "$warn_percent" \
  --argjson criticalPercent "$critical_percent" \
  --argjson paths "$paths_json" \
  --argjson skippedDuplicateDevices "$skipped_duplicate_paths" \
  '{schemaVersion:1,event:$event,timestamp:$timestamp,state:$state,failureClass:$failureClass,reason:$reason,message:$message,operatorActionRequired:$operatorActionRequired,alertRequired:$alertRequired,alertSuppressed:$alertSuppressed,warnPercent:$warnPercent,criticalPercent:$criticalPercent,paths:$paths,skippedDuplicateDevices:$skippedDuplicateDevices}')"

write_atomic "$status_file" "$status_dir" "$status_name" "$event_json"
printf '%s\n' "$event_json"
[[ "$alert_required" == false ]]
