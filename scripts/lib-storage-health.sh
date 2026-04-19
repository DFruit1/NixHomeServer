#!/usr/bin/env bash

storage_health_run_command() {
  if declare -p storage_health_cmd_prefix >/dev/null 2>&1; then
    "${storage_health_cmd_prefix[@]}" "$@"
  else
    "$@"
  fi
}

storage_health_note() {
  local message="$1"

  if [[ -n "${STORAGE_HEALTH_LAST_DETAIL:-}" ]]; then
    STORAGE_HEALTH_LAST_DETAIL+="; ${message}"
  else
    STORAGE_HEALTH_LAST_DETAIL="${message}"
  fi
}

storage_health_attr_value() {
  local smart_output="$1"
  local attribute="$2"
  local raw_value

  raw_value="$(
    awk -v attribute="$attribute" '
      $2 == attribute {
        print $NF
        exit
      }
    ' <<<"$smart_output"
  )"

  raw_value="${raw_value//[^0-9]/}"
  if [[ -n "$raw_value" ]]; then
    printf '%s\n' "$raw_value"
  else
    printf '0\n'
  fi
}

storage_health_kernel_log() {
  if [[ -z "${STORAGE_HEALTH_KERNEL_LOG_CACHE_READY:-}" ]]; then
    STORAGE_HEALTH_KERNEL_LOG_CACHE="$(
      storage_health_run_command \
        "${STORAGE_HEALTH_JOURNALCTL_BIN:-journalctl}" \
        -k \
        --since "${STORAGE_HEALTH_JOURNAL_SINCE:-7 days ago}" \
        --no-pager 2>&1 || true
    )"
    STORAGE_HEALTH_KERNEL_LOG_CACHE_READY=1
  fi

  printf '%s\n' "$STORAGE_HEALTH_KERNEL_LOG_CACHE"
}

storage_health_transport_events() {
  local device="$1"
  local resolved_device short_device
  local kernel_log

  resolved_device="$(readlink -f "$device" 2>/dev/null || printf '%s' "$device")"
  short_device="$(basename "$resolved_device")"
  kernel_log="$(storage_health_kernel_log)"

  if [[ -z "$short_device" ]]; then
    return 0
  fi

  awk -v short_device="$short_device" '
    BEGIN {
      IGNORECASE = 1
    }

    $0 ~ short_device &&
      ($0 ~ /hardreset/ ||
       $0 ~ /reset/ ||
       $0 ~ /disable device/ ||
       $0 ~ /i\/o error/ ||
       $0 ~ /frozen/ ||
       $0 ~ /failed command/ ||
       $0 ~ /exception/) {
      print
    }
  ' <<<"$kernel_log"
}

storage_health_assess_disk() {
  local device="$1"
  local label="$2"
  local smart_output smart_status overall_status
  local current_pending offline_uncorrect reallocated reported_uncorrect crc_errors power_on_hours
  local transport_events transport_count
  local had_errexit=0

  STORAGE_HEALTH_LAST_SEVERITY="OK"
  STORAGE_HEALTH_LAST_DETAIL=""

  if [[ $- == *e* ]]; then
    had_errexit=1
  fi
  set +e
  smart_output="$(
    storage_health_run_command \
      "${STORAGE_HEALTH_SMARTCTL_BIN:-smartctl}" \
      -d sat \
      -x \
      "$device" 2>&1
  )"
  smart_status=$?
  if (( had_errexit != 0 )); then
    set -e
  fi

  if [[ $smart_status -ne 0 ]] && ! grep -Eq 'SMART support is:|Serial Number:|Device Model:' <<<"$smart_output"; then
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "SMART unreadable"
  fi

  overall_status="unknown"
  if grep -Eq 'SMART overall-health self-assessment test result:[[:space:]]*PASSED|SMART Health Status:[[:space:]]*OK' <<<"$smart_output"; then
    overall_status="passed"
  elif grep -Eq 'SMART overall-health self-assessment test result:[[:space:]]*(FAILED|FAIL)|SMART Health Status:[[:space:]]*(BAD|FAIL|FAILED)' <<<"$smart_output"; then
    overall_status="failed"
  fi

  if [[ "$overall_status" == "failed" ]]; then
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "SMART overall status failed"
  fi

  current_pending="$(storage_health_attr_value "$smart_output" "Current_Pending_Sector")"
  offline_uncorrect="$(storage_health_attr_value "$smart_output" "Offline_Uncorrectable")"
  reallocated="$(storage_health_attr_value "$smart_output" "Reallocated_Sector_Ct")"
  reported_uncorrect="$(storage_health_attr_value "$smart_output" "Reported_Uncorrect")"
  crc_errors="$(storage_health_attr_value "$smart_output" "UDMA_CRC_Error_Count")"
  power_on_hours="$(storage_health_attr_value "$smart_output" "Power_On_Hours")"

  if (( current_pending > 0 )); then
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "Current_Pending_Sector=${current_pending}"
  fi

  if (( offline_uncorrect > 0 )); then
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "Offline_Uncorrectable=${offline_uncorrect}"
  fi

  if (( reallocated > 0 )) && [[ "$STORAGE_HEALTH_LAST_SEVERITY" != "CRITICAL" ]]; then
    STORAGE_HEALTH_LAST_SEVERITY="WARN"
    storage_health_note "Reallocated_Sector_Ct=${reallocated}"
  fi

  if (( reported_uncorrect > 0 )) && [[ "$STORAGE_HEALTH_LAST_SEVERITY" != "CRITICAL" ]]; then
    STORAGE_HEALTH_LAST_SEVERITY="WARN"
    storage_health_note "Reported_Uncorrect=${reported_uncorrect}"
  fi

  if (( crc_errors > 0 )) && [[ "$STORAGE_HEALTH_LAST_SEVERITY" != "CRITICAL" ]]; then
    STORAGE_HEALTH_LAST_SEVERITY="WARN"
    storage_health_note "UDMA_CRC_Error_Count=${crc_errors}"
  fi

  if grep -Eq 'ATA Error Count:[[:space:]]*[1-9][0-9]*' <<<"$smart_output" \
    || grep -Eq '^# [[:space:]]*[0-9]+.*Completed:[[:space:]]*(read failure|unknown failure|servo/seek failure|electrical failure)' <<<"$smart_output" \
    || grep -Eq 'Error [0-9]+ occurred at disk power-on lifetime:' <<<"$smart_output"; then
    if [[ "$STORAGE_HEALTH_LAST_SEVERITY" != "CRITICAL" ]]; then
      STORAGE_HEALTH_LAST_SEVERITY="WARN"
    fi
    storage_health_note "historical SMART self-test or error-log failures"
  fi

  if (( power_on_hours >= ${STORAGE_HEALTH_HIGH_HOURS_THRESHOLD:-40000} )) && [[ "$STORAGE_HEALTH_LAST_SEVERITY" == "OK" ]]; then
    storage_health_note "Power_On_Hours=${power_on_hours}"
  fi

  transport_events="$(storage_health_transport_events "$device")"
  if [[ -n "$transport_events" ]]; then
    transport_count="$(printf '%s\n' "$transport_events" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "recent kernel transport errors (${transport_count})"
  fi

  if [[ -z "$STORAGE_HEALTH_LAST_DETAIL" ]]; then
    STORAGE_HEALTH_LAST_DETAIL="no degradation signals"
  fi

  printf '%-8s %-12s %s\n' "$STORAGE_HEALTH_LAST_SEVERITY" "$label" "$device"
  printf '  %s\n' "$STORAGE_HEALTH_LAST_DETAIL"
}

storage_health_check() {
  local mode="${1:-warn}"
  shift || true

  STORAGE_HEALTH_OK_COUNT=0
  STORAGE_HEALTH_WARN_COUNT=0
  STORAGE_HEALTH_CRITICAL_COUNT=0

  printf '%-8s %-12s %s\n' "STATUS" "DISK" "DEVICE"

  local spec label device
  for spec in "$@"; do
    label="${spec%%=*}"
    device="${spec#*=}"
    if [[ "$label" == "$device" ]]; then
      label="$(basename "$device")"
    fi

    storage_health_assess_disk "$device" "$label"
    case "$STORAGE_HEALTH_LAST_SEVERITY" in
      OK)
        STORAGE_HEALTH_OK_COUNT=$((STORAGE_HEALTH_OK_COUNT + 1))
        ;;
      WARN)
        STORAGE_HEALTH_WARN_COUNT=$((STORAGE_HEALTH_WARN_COUNT + 1))
        ;;
      CRITICAL)
        STORAGE_HEALTH_CRITICAL_COUNT=$((STORAGE_HEALTH_CRITICAL_COUNT + 1))
        ;;
      *)
        STORAGE_HEALTH_CRITICAL_COUNT=$((STORAGE_HEALTH_CRITICAL_COUNT + 1))
        ;;
    esac
  done

  printf 'Summary: %s OK, %s WARN, %s CRITICAL\n' \
    "$STORAGE_HEALTH_OK_COUNT" \
    "$STORAGE_HEALTH_WARN_COUNT" \
    "$STORAGE_HEALTH_CRITICAL_COUNT"

  if [[ "$mode" == "strict" ]] && (( STORAGE_HEALTH_CRITICAL_COUNT > 0 )); then
    return 1
  fi
}

storage_health_main() {
  set -euo pipefail

  local mode="warn"
  local specs=()

  if (( EUID != 0 )) && command -v sudo >/dev/null 2>&1; then
    storage_health_cmd_prefix=(sudo)
  fi

  while (($# > 0)); do
    case "$1" in
      --mode)
        mode="$2"
        shift 2
        ;;
      --since)
        STORAGE_HEALTH_JOURNAL_SINCE="$2"
        shift 2
        ;;
      --high-hours-threshold)
        STORAGE_HEALTH_HIGH_HOURS_THRESHOLD="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'EOF'
Usage: scripts/lib-storage-health.sh [--mode warn|strict] [--since "<journalctl window>"] label=/dev/disk/by-id/...
EOF
        return 0
        ;;
      *)
        specs+=("$1")
        shift
        ;;
    esac
  done

  if ((${#specs[@]} == 0)); then
    echo "No devices supplied." >&2
    return 1
  fi

  storage_health_check "$mode" "${specs[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  storage_health_main "$@"
fi
