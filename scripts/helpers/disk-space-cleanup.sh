#!/usr/bin/env bash

set -euo pipefail

trigger_percent="${DISK_CLEANUP_TRIGGER_PERCENT:-85}"
monitor_paths_str="${DISK_CLEANUP_MONITOR_PATHS:-/}"
journal_vacuum_time="${DISK_CLEANUP_JOURNAL_VACUUM_TIME:-7d}"
nix_gc_retention_days="${DISK_CLEANUP_NIX_GC_RETENTION_DAYS:-45}"
lock_path="${DISK_CLEANUP_LOCK_PATH:-/run/lock/nixhomeserver-maintenance.lock}"
failure_marker="${DISK_CLEANUP_FAILURE_MARKER:-}"
store_path="${DISK_CLEANUP_STORE_PATH:-/nix/store}"
nix_gc_override="${DISK_CLEANUP_NIX_GC_ENABLED:-}"
invocation_id="${INVOCATION_ID:-manual}"
stage="configuration_validation"

if [[ ! "$invocation_id" =~ ^[A-Fa-f0-9]{16,64}$ ]]; then
  invocation_id="manual"
fi
[[ -n "$monitor_paths_str" ]] || monitor_paths_str="/"
read -ra monitor_paths <<<"$monitor_paths_str"

log_failure() {
  local exit_status="$1"
  local collector_output_base64="${2:-}"
  local output_truncated="${3:-false}"
  if [[ -n "$failure_marker" ]]; then
    touch -- "$failure_marker" 2>/dev/null || true
  fi
  if [[ -n "$collector_output_base64" ]]; then
    printf >&2 \
      '{"event":"disk_cleanup_failed","invocation_id":"%s","stage":"%s","exit_status":%d,"collector_output_base64":"%s","collector_output_truncated":%s}\n' \
      "$invocation_id" \
      "$stage" \
      "$exit_status" \
      "$collector_output_base64" \
      "$output_truncated"
  else
    printf >&2 \
      '{"event":"disk_cleanup_failed","invocation_id":"%s","stage":"%s","exit_status":%d}\n' \
      "$invocation_id" \
      "$stage" \
      "$exit_status"
  fi
}

on_error() {
  local exit_status=$?
  trap - ERR
  log_failure "$exit_status"
  exit "$exit_status"
}

trap on_error ERR

if [[ ! "$trigger_percent" =~ ^[1-9][0-9]*$ ]] || ((trigger_percent > 100)); then
  log_failure 64
  exit 64
fi
if [[ ! "$journal_vacuum_time" =~ ^[0-9]+[smhdw]$ ]]; then
  log_failure 64
  exit 64
fi
if [[ ! "$nix_gc_retention_days" =~ ^[1-9][0-9]*$ ]] \
  || ((nix_gc_retention_days > 36500)); then
  log_failure 64
  exit 64
fi
if (( ${#monitor_paths[@]} == 0 )); then
  log_failure 64
  exit 64
fi

measure_capacity() {
  local -a device_lines=()
  local path dev total used line percent duplicate
  local capacity_file store_dev
  capacity_json='[]'
  max_used_percent=0
  total_used_bytes=0
  pressure=false
  for path in "${monitor_paths[@]}"; do
    [[ -d "$path" ]] || continue
    dev="$(stat -c %d -- "$path")"
    duplicate=false
    for line in "${device_lines[@]}"; do
      if [[ "${line%%|*}" == "$dev" ]]; then
        duplicate=true
      fi
    done
    if [[ "$duplicate" == true ]]; then
      continue
    fi
    read -r total used < <(df --output=size,used --block-size=1 -- "$path" | tail -n 1)
    if [[ ! "$total" =~ ^[1-9][0-9]*$ ]] \
      || [[ ! "$used" =~ ^[0-9]+$ ]] \
      || ((used > total)); then
      return 65
    fi
    device_lines+=("${dev}|${path}|${total}|${used}")
  done
  if (( ${#device_lines[@]} == 0 )); then
    return 65
  fi

  capacity_file="$(mktemp)"
  for line in "${device_lines[@]}"; do
    IFS='|' read -r dev path total used <<<"$line"
    if ((used * 100 >= total * trigger_percent)); then
      pressure=true
    fi
    percent=$((used * 100 / total))
    if ((percent > max_used_percent)); then
      max_used_percent=$percent
    fi
    total_used_bytes=$((total_used_bytes + used))
    jq -nc \
      --arg path "$path" \
      --arg device "$dev" \
      --argjson used "$used" \
      --argjson total "$total" \
      --argjson percent "$percent" \
      '{path:$path,device:$device,usedBytes:$used,totalBytes:$total,usedPercent:$percent}' \
      >>"$capacity_file"
  done
  capacity_json="$(jq -s . "$capacity_file")"
  rm -f -- "$capacity_file"

  store_monitored=false
  if [[ -d "$store_path" ]]; then
    store_dev="$(stat -c %d -- "$store_path")"
    for line in "${device_lines[@]}"; do
      if [[ "${line%%|*}" == "$store_dev" ]]; then
        store_monitored=true
      fi
    done
  fi
}

stage="capacity_measurement"
measure_capacity

nix_gc_enabled=false
if [[ "$store_monitored" == true && "$nix_gc_override" != "0" ]]; then
  nix_gc_enabled=true
fi

decision="skip"
if [[ "$pressure" == true ]]; then
  decision="cleanup"
fi

printf \
  '{"event":"disk_cleanup_check","invocation_id":"%s","decision":"%s","trigger_percent":%d,"max_used_percent":%d,"total_used_bytes":%d,"store_monitored":%s,"nix_gc_enabled":%s,"devices":%s}\n' \
  "$invocation_id" \
  "$decision" \
  "$trigger_percent" \
  "$max_used_percent" \
  "$total_used_bytes" \
  "$store_monitored" \
  "$nix_gc_enabled" \
  "$capacity_json"

if [[ "$decision" == "skip" ]]; then
  exit 0
fi

stage="maintenance_lock"
install -d -m 0755 -- "$(dirname -- "$lock_path")"
exec 9>"$lock_path"
if ! flock -n 9; then
  printf \
    '{"event":"disk_cleanup_deferred","invocation_id":"%s","reason":"maintenance_lock_busy"}\n' \
    "$invocation_id"
  exit 75
fi

stage="capacity_remeasurement"
measure_capacity

decision="skip"
if [[ "$pressure" == true ]]; then
  decision="cleanup"
fi

printf \
  '{"event":"disk_cleanup_recheck","invocation_id":"%s","decision":"%s","max_used_percent":%d,"total_used_bytes":%d,"devices":%s}\n' \
  "$invocation_id" \
  "$decision" \
  "$max_used_percent" \
  "$total_used_bytes" \
  "$capacity_json"

if [[ "$decision" == "skip" ]]; then
  exit 0
fi

stage="cleanup_started"
nix_gc_enabled=false
if [[ "$store_monitored" == true && "$nix_gc_override" != "0" ]]; then
  nix_gc_enabled=true
fi
actions_json='["journald_vacuum","tmpfiles_clean"]'
if [[ "$nix_gc_enabled" == true ]]; then
  actions_json='["journald_vacuum","tmpfiles_clean","nix_store_gc"]'
fi

printf \
  '{"event":"disk_cleanup_started","invocation_id":"%s","trigger_percent":%d,"max_used_percent":%d,"total_used_bytes":%d,"actions":%s}\n' \
  "$invocation_id" \
  "$trigger_percent" \
  "$max_used_percent" \
  "$total_used_bytes" \
  "$actions_json"

used_before=$total_used_bytes
action_results='[]'
overall_failure=0

run_action() {
  local name="$1"
  local output_file action_status output_b64 output_size output_truncated
  shift
  output_file="$(mktemp)"
  action_status=0
  if "$@" >"$output_file" 2>&1; then
    :
  else
    action_status=$?
  fi
  if ((action_status != 0)); then
    if ((overall_failure == 0)); then
      overall_failure=$action_status
    fi
    output_size=0
    output_b64=""
    if [[ -s "$output_file" ]]; then
      output_size="$(wc -c <"$output_file")"
      output_b64="$(tail -c 4096 -- "$output_file" | base64 -w 0)"
    fi
    output_truncated=false
    if ((output_size > 4096)); then
      output_truncated=true
    fi
    if [[ -n "$output_b64" ]]; then
      printf \
        '{"event":"disk_cleanup_action_failed","invocation_id":"%s","action":"%s","exit_status":%d,"output_base64":"%s","output_truncated":%s}\n' \
        "$invocation_id" \
        "$name" \
        "$action_status" \
        "$output_b64" \
        "$output_truncated"
    else
      printf \
        '{"event":"disk_cleanup_action_failed","invocation_id":"%s","action":"%s","exit_status":%d}\n' \
        "$invocation_id" \
        "$name" \
        "$action_status"
    fi
  fi
  action_results="$(jq -nc \
    --argjson results "$action_results" \
    --arg name "$name" \
    --argjson status "$action_status" \
    '$results + [{name:$name,status:$status}]')"
  rm -f -- "$output_file"
}

run_action journald_vacuum journalctl --vacuum-time="$journal_vacuum_time"
run_action tmpfiles_clean systemd-tmpfiles --clean
if [[ "$nix_gc_enabled" == true ]]; then
  run_action nix_store_gc nix-collect-garbage --delete-older-than "${nix_gc_retention_days}d"
fi

stage="post_cleanup_measurement"
measure_capacity

used_after=$total_used_bytes
freed_bytes=0
if ((used_after < used_before)); then
  freed_bytes=$((used_before - used_after))
fi

printf \
  '{"event":"disk_cleanup_completed","invocation_id":"%s","max_used_percent":%d,"used_before":%d,"used_after":%d,"freed_bytes":%d,"actions":%s}\n' \
  "$invocation_id" \
  "$max_used_percent" \
  "$used_before" \
  "$used_after" \
  "$freed_bytes" \
  "$action_results"

if ((overall_failure != 0)); then
  log_failure "$overall_failure"
  exit "$overall_failure"
fi