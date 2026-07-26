#!/usr/bin/env bash

set -euo pipefail

trigger_percent=90
store_path="${NIX_STORE_PATH:-/nix/store}"
lock_path="${NIX_GC_LOCK_PATH:-/run/lock/nixhomeserver-maintenance.lock}"
invocation_id="${INVOCATION_ID:-manual}"
failure_marker="${NIX_GC_FAILURE_MARKER:-}"
stage="configuration_validation"
gc_output_file=""

if [[ ! "$invocation_id" =~ ^[A-Fa-f0-9]{16,64}$ ]]; then
  invocation_id="manual"
fi

log_failure() {
  local exit_status="$1"
  local collector_output_base64="${2:-}"
  local output_truncated="${3:-false}"
  if [[ -n "$failure_marker" ]]; then
    touch -- "$failure_marker" 2>/dev/null || true
  fi
  if [[ -n "$collector_output_base64" ]]; then
    printf >&2 \
      '{"event":"nix_store_gc_failed","invocation_id":"%s","stage":"%s","exit_status":%d,"collector_output_base64":"%s","collector_output_truncated":%s}\n' \
      "$invocation_id" \
      "$stage" \
      "$exit_status" \
      "$collector_output_base64" \
      "$output_truncated"
  else
    printf >&2 \
      '{"event":"nix_store_gc_failed","invocation_id":"%s","stage":"%s","exit_status":%d}\n' \
      "$invocation_id" \
      "$stage" \
      "$exit_status"
  fi
}

cleanup() {
  if [[ -n "$gc_output_file" ]]; then
    rm -f -- "$gc_output_file"
  fi
}

on_error() {
  local exit_status=$?
  trap - ERR
  log_failure "$exit_status"
  exit "$exit_status"
}

trap cleanup EXIT
trap on_error ERR

if [[ ! "${NIX_STORE_MAX_GIB:-}" =~ ^[1-9][0-9]*$ ]] \
  || ((NIX_STORE_MAX_GIB > 1048576)); then
  log_failure 64
  exit 64
fi
if [[ ! "${NIX_GC_RETENTION_DAYS:-}" =~ ^[1-9][0-9]*$ ]] \
  || ((NIX_GC_RETENTION_DAYS > 36500)); then
  log_failure 64
  exit 64
fi
if [[ ! -d "$store_path" ]]; then
  log_failure 66
  exit 66
fi

read_store_bytes() {
  local bytes
  read -r bytes _ < <(du -sx --block-size=1 -- "$store_path")
  if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then
    return 65
  fi
  printf '%s\n' "$bytes"
}

read_filesystem_bytes() {
  local total_bytes used_bytes
  read -r total_bytes used_bytes \
    < <(df --output=size,used --block-size=1 -- "$store_path" | tail -n 1)
  if [[ ! "$total_bytes" =~ ^[1-9][0-9]*$ ]] \
    || [[ ! "$used_bytes" =~ ^[0-9]+$ ]] \
    || ((used_bytes > total_bytes)); then
    return 65
  fi
  printf '%s %s\n' "$total_bytes" "$used_bytes"
}

limit_bytes=$((NIX_STORE_MAX_GIB * 1024 * 1024 * 1024))
trigger_bytes=$((limit_bytes * trigger_percent / 100))

measure_capacity() {
  store_bytes="$(read_store_bytes)"
  read -r filesystem_total_bytes filesystem_used_bytes \
    < <(read_filesystem_bytes)
  filesystem_used_percent=$((filesystem_used_bytes * 100 / filesystem_total_bytes))

  store_at_capacity=false
  filesystem_at_capacity=false
  if ((store_bytes >= trigger_bytes)); then
    store_at_capacity=true
  fi
  if ((filesystem_used_bytes * 100 >= filesystem_total_bytes * trigger_percent)); then
    filesystem_at_capacity=true
  fi

  if [[ "$store_at_capacity" == true && "$filesystem_at_capacity" == true ]]; then
    trigger_reason="store_and_filesystem_capacity"
  elif [[ "$store_at_capacity" == true ]]; then
    trigger_reason="store_size"
  elif [[ "$filesystem_at_capacity" == true ]]; then
    trigger_reason="filesystem_capacity"
  else
    trigger_reason="below_threshold"
  fi

  decision="skip"
  if [[ "$store_at_capacity" == true || "$filesystem_at_capacity" == true ]]; then
    decision="collect"
  fi
}

stage="capacity_measurement"
measure_capacity

printf \
  '{"event":"nix_store_gc_check","invocation_id":"%s","decision":"%s","trigger_reason":"%s","store_bytes":%d,"configured_limit_bytes":%d,"trigger_bytes":%d,"trigger_percent":%d,"filesystem_used_bytes":%d,"filesystem_total_bytes":%d,"filesystem_used_percent":%d,"retention_days":%d}\n' \
  "$invocation_id" \
  "$decision" \
  "$trigger_reason" \
  "$store_bytes" \
  "$limit_bytes" \
  "$trigger_bytes" \
  "$trigger_percent" \
  "$filesystem_used_bytes" \
  "$filesystem_total_bytes" \
  "$filesystem_used_percent" \
  "$NIX_GC_RETENTION_DAYS"

if [[ "$decision" == "skip" ]]; then
  exit 0
fi

stage="maintenance_lock"
install -d -m 0755 -- "$(dirname -- "$lock_path")"
exec 9>"$lock_path"
if ! flock -n 9; then
  printf \
    '{"event":"nix_store_gc_deferred","invocation_id":"%s","reason":"maintenance_lock_busy"}\n' \
    "$invocation_id"
  exit 75
fi

stage="capacity_remeasurement"
measure_capacity
printf \
  '{"event":"nix_store_gc_recheck","invocation_id":"%s","decision":"%s","trigger_reason":"%s","store_bytes":%d,"filesystem_used_bytes":%d,"filesystem_total_bytes":%d}\n' \
  "$invocation_id" \
  "$decision" \
  "$trigger_reason" \
  "$store_bytes" \
  "$filesystem_used_bytes" \
  "$filesystem_total_bytes"
if [[ "$decision" == "skip" ]]; then
  exit 0
fi

printf \
  '{"event":"nix_store_gc_started","invocation_id":"%s","trigger_reason":"%s","store_bytes_before":%d,"retention_days":%d}\n' \
  "$invocation_id" \
  "$trigger_reason" \
  "$store_bytes" \
  "$NIX_GC_RETENTION_DAYS"

stage="garbage_collection"
gc_output_file="$(mktemp)"
gc_status=0
if nix-collect-garbage --delete-older-than "${NIX_GC_RETENTION_DAYS}d" \
  >"$gc_output_file" 2>&1; then
  :
else
  gc_status=$?
fi
if ((gc_status != 0)); then
  gc_output_size="$(wc -c <"$gc_output_file")"
  collector_output_base64="$(tail -c 8192 -- "$gc_output_file" | base64 -w 0)"
  output_truncated=false
  if ((gc_output_size > 8192)); then
    output_truncated=true
  fi
  log_failure "$gc_status" "$collector_output_base64" "$output_truncated"
  exit "$gc_status"
fi

stage="post_collection_measurement"
store_bytes_after="$(read_store_bytes)"
freed_bytes=0
if ((store_bytes_after < store_bytes)); then
  freed_bytes=$((store_bytes - store_bytes_after))
fi

printf \
  '{"event":"nix_store_gc_completed","invocation_id":"%s","trigger_reason":"%s","store_bytes_before":%d,"store_bytes_after":%d,"freed_bytes":%d,"retention_days":%d}\n' \
  "$invocation_id" \
  "$trigger_reason" \
  "$store_bytes" \
  "$store_bytes_after" \
  "$freed_bytes" \
  "$NIX_GC_RETENTION_DAYS"
