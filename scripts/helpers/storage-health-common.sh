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

storage_health_self_test_status() {
  local smart_output="$1"
  local status

  status="$(
    awk '
      BEGIN {
        in_log = 0
      }

      /^SMART Self-test log/ || /^SMART Extended Comprehensive Error Log/ {
        in_log = 1
        next
      }

      in_log && /^#/ {
        sub(/^#[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
        split($0, parts, /[[:space:]]{2,}/)
        print parts[1]
        exit
      }
    ' <<<"$smart_output"
  )"

  case "$status" in
    Completed\ without\ error*)
      printf 'passed\n'
      ;;
    Completed:*)
      printf 'failed\n'
      ;;
    Self-test\ routine\ in\ progress*|Aborted\ by*)
      printf 'in_progress\n'
      ;;
    "")
      printf 'none\n'
      ;;
    *)
      printf 'unknown\n'
      ;;
  esac
}

storage_health_emit_json() {
  jq -nc \
    --arg label "$STORAGE_HEALTH_LAST_LABEL" \
    --arg device "$STORAGE_HEALTH_LAST_DEVICE" \
    --arg group "$STORAGE_HEALTH_LAST_GROUP" \
    --arg actualDevice "$STORAGE_HEALTH_LAST_ACTUAL_DEVICE" \
    --arg severity "$STORAGE_HEALTH_LAST_SEVERITY" \
    --arg detail "$STORAGE_HEALTH_LAST_DETAIL" \
    --arg overallStatus "$STORAGE_HEALTH_LAST_SMART_OVERALL_STATUS" \
    --arg selfTestStatus "$STORAGE_HEALTH_LAST_SELF_TEST_STATUS" \
    --argjson smartctlArgs "$STORAGE_HEALTH_LAST_SMARTCTL_ARGS_JSON" \
    --argjson smartReadable "$STORAGE_HEALTH_LAST_SMART_READABLE" \
    --argjson currentPending "$STORAGE_HEALTH_LAST_CURRENT_PENDING" \
    --argjson offlineUncorrectable "$STORAGE_HEALTH_LAST_OFFLINE_UNCORRECTABLE" \
    --argjson reallocatedSectors "$STORAGE_HEALTH_LAST_REALLOCATED" \
    --argjson reportedUncorrect "$STORAGE_HEALTH_LAST_REPORTED_UNCORRECT" \
    --argjson crcErrors "$STORAGE_HEALTH_LAST_CRC_ERRORS" \
    --argjson powerOnHours "$STORAGE_HEALTH_LAST_POWER_ON_HOURS" \
    --argjson transportEventCount "$STORAGE_HEALTH_LAST_TRANSPORT_COUNT" \
    '{
      label: $label,
      device: $device,
      group: $group,
      actualDevice: $actualDevice,
      severity: $severity,
      detail: $detail,
      smartctlArgs: $smartctlArgs,
      smartReadable: $smartReadable,
      smartOverallStatus: $overallStatus,
      lastSelfTestStatus: $selfTestStatus,
      attributes: {
        currentPendingSector: $currentPending,
        offlineUncorrectable: $offlineUncorrectable,
        reallocatedSectorCount: $reallocatedSectors,
        reportedUncorrect: $reportedUncorrect,
        udmaCrcErrorCount: $crcErrors,
        powerOnHours: $powerOnHours
      },
      transportEventCount: $transportEventCount
    }'
}

storage_health_assess_disk() {
  local device="$1"
  local label="$2"
  local group="${3:-}"
  local actual_device="${4:-$device}"
  shift 4 || true
  local smartctl_args=("$@")
  local smart_output smart_status overall_status
  local current_pending offline_uncorrect reallocated reported_uncorrect crc_errors power_on_hours
  local transport_events transport_count
  local had_errexit=0

  STORAGE_HEALTH_LAST_LABEL="$label"
  STORAGE_HEALTH_LAST_DEVICE="$device"
  STORAGE_HEALTH_LAST_GROUP="$group"
  STORAGE_HEALTH_LAST_ACTUAL_DEVICE="$actual_device"
  STORAGE_HEALTH_LAST_SEVERITY="OK"
  STORAGE_HEALTH_LAST_DETAIL=""
  STORAGE_HEALTH_LAST_SMARTCTL_ARGS_JSON="$(jq -nc --args '$ARGS.positional' -- "${smartctl_args[@]}")"
  STORAGE_HEALTH_LAST_SMART_READABLE=true
  STORAGE_HEALTH_LAST_SMART_OVERALL_STATUS="unknown"
  STORAGE_HEALTH_LAST_SELF_TEST_STATUS="unknown"
  STORAGE_HEALTH_LAST_CURRENT_PENDING=0
  STORAGE_HEALTH_LAST_OFFLINE_UNCORRECTABLE=0
  STORAGE_HEALTH_LAST_REALLOCATED=0
  STORAGE_HEALTH_LAST_REPORTED_UNCORRECT=0
  STORAGE_HEALTH_LAST_CRC_ERRORS=0
  STORAGE_HEALTH_LAST_POWER_ON_HOURS=0
  STORAGE_HEALTH_LAST_TRANSPORT_COUNT=0

  if [[ $- == *e* ]]; then
    had_errexit=1
  fi
  set +e
  smart_output="$(
    storage_health_run_command \
      "${STORAGE_HEALTH_SMARTCTL_BIN:-smartctl}" \
      "${smartctl_args[@]}" \
      -x \
      "$device" 2>&1
  )"
  smart_status=$?
  if (( had_errexit != 0 )); then
    set -e
  fi

  if [[ $smart_status -ne 0 ]] && ! grep -Eq 'SMART support is:|Serial Number:|Device Model:' <<<"$smart_output"; then
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    STORAGE_HEALTH_LAST_SMART_READABLE=false
    storage_health_note "SMART unreadable"
  fi

  overall_status="unknown"
  if grep -Eq 'SMART overall-health self-assessment test result:[[:space:]]*PASSED|SMART Health Status:[[:space:]]*OK' <<<"$smart_output"; then
    overall_status="passed"
  elif grep -Eq 'SMART overall-health self-assessment test result:[[:space:]]*(FAILED|FAIL)|SMART Health Status:[[:space:]]*(BAD|FAIL|FAILED)' <<<"$smart_output"; then
    overall_status="failed"
  fi
  STORAGE_HEALTH_LAST_SMART_OVERALL_STATUS="$overall_status"
  STORAGE_HEALTH_LAST_SELF_TEST_STATUS="$(storage_health_self_test_status "$smart_output")"

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

  STORAGE_HEALTH_LAST_CURRENT_PENDING="$current_pending"
  STORAGE_HEALTH_LAST_OFFLINE_UNCORRECTABLE="$offline_uncorrect"
  STORAGE_HEALTH_LAST_REALLOCATED="$reallocated"
  STORAGE_HEALTH_LAST_REPORTED_UNCORRECT="$reported_uncorrect"
  STORAGE_HEALTH_LAST_CRC_ERRORS="$crc_errors"
  STORAGE_HEALTH_LAST_POWER_ON_HOURS="$power_on_hours"

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

  if [[ "$STORAGE_HEALTH_LAST_SELF_TEST_STATUS" == "failed" ]]; then
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "last SMART self-test failed"
  fi

  if (( power_on_hours >= ${STORAGE_HEALTH_HIGH_HOURS_THRESHOLD:-40000} )) && [[ "$STORAGE_HEALTH_LAST_SEVERITY" == "OK" ]]; then
    storage_health_note "Power_On_Hours=${power_on_hours}"
  fi

  transport_events="$(storage_health_transport_events "$device")"
  if [[ -n "$transport_events" ]]; then
    transport_count="$(printf '%s\n' "$transport_events" | sed '/^$/d' | wc -l | tr -d '[:space:]')"
    STORAGE_HEALTH_LAST_TRANSPORT_COUNT="$transport_count"
    STORAGE_HEALTH_LAST_SEVERITY="CRITICAL"
    storage_health_note "recent kernel transport errors (${transport_count})"
  fi

  if [[ -z "$STORAGE_HEALTH_LAST_DETAIL" ]]; then
    STORAGE_HEALTH_LAST_DETAIL="no degradation signals"
  fi
}

storage_health_process_last_result() {
  local output_format="${STORAGE_HEALTH_OUTPUT_FORMAT:-text}"

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

  if [[ "$output_format" == "json" ]]; then
    STORAGE_HEALTH_DISK_JSON+=("$(storage_health_emit_json)")
  else
    printf '%-8s %-12s %s\n' "$STORAGE_HEALTH_LAST_SEVERITY" "$STORAGE_HEALTH_LAST_LABEL" "$STORAGE_HEALTH_LAST_DEVICE"
    printf '  %s\n' "$STORAGE_HEALTH_LAST_DETAIL"
  fi
}

storage_health_check() {
  local mode="${1:-warn}"
  shift || true

  STORAGE_HEALTH_OK_COUNT=0
  STORAGE_HEALTH_WARN_COUNT=0
  STORAGE_HEALTH_CRITICAL_COUNT=0

  local output_format="${STORAGE_HEALTH_OUTPUT_FORMAT:-text}"
  STORAGE_HEALTH_DISK_JSON=()

  if [[ "$output_format" == "text" ]]; then
    printf '%-8s %-12s %s\n' "STATUS" "DISK" "DEVICE"
  fi

  local spec_json label device group actual_device
  local smartctl_args=()
  if [[ -n "${STORAGE_HEALTH_SPEC_FILE:-}" ]]; then
    while IFS= read -r spec_json; do
      [[ -n "$spec_json" ]] || continue
      label="$(jq -r '.label // empty' <<<"$spec_json")"
      device="$(jq -r '.device // empty' <<<"$spec_json")"
      group="$(jq -r '.group // ""' <<<"$spec_json")"
      actual_device="$(jq -r '.actualDevice // .device // empty' <<<"$spec_json")"
      if [[ -z "$device" ]]; then
        continue
      fi
      if [[ -z "$label" ]]; then
        label="$(basename "$device")"
      fi
      mapfile -t smartctl_args < <(jq -r '.smartctlArgs // [] | .[]' <<<"$spec_json")
      storage_health_assess_disk "$device" "$label" "$group" "$actual_device" "${smartctl_args[@]}"
      storage_health_process_last_result
    done < <(jq -c '.[]' "$STORAGE_HEALTH_SPEC_FILE")
  fi

  local spec label device
  for spec in "$@"; do
    label="${spec%%=*}"
    device="${spec#*=}"
    if [[ "$label" == "$device" ]]; then
      label="$(basename "$device")"
    fi

    storage_health_assess_disk "$device" "$label" "" "$device"
    storage_health_process_last_result
  done

  if [[ "$output_format" == "json" ]]; then
    if ((${#STORAGE_HEALTH_DISK_JSON[@]} == 0)); then
      jq -nc \
        --arg mode "$mode" \
        --argjson ok "$STORAGE_HEALTH_OK_COUNT" \
        --argjson warn "$STORAGE_HEALTH_WARN_COUNT" \
        --argjson critical "$STORAGE_HEALTH_CRITICAL_COUNT" \
        '{mode: $mode, summary: {ok: $ok, warn: $warn, critical: $critical}, disks: []}'
    else
      printf '%s\n' "${STORAGE_HEALTH_DISK_JSON[@]}" | jq -sc \
        --arg mode "$mode" \
        --argjson ok "$STORAGE_HEALTH_OK_COUNT" \
        --argjson warn "$STORAGE_HEALTH_WARN_COUNT" \
        --argjson critical "$STORAGE_HEALTH_CRITICAL_COUNT" \
        '{mode: $mode, summary: {ok: $ok, warn: $warn, critical: $critical}, disks: .}'
    fi
  else
    printf 'Summary: %s OK, %s WARN, %s CRITICAL\n' \
      "$STORAGE_HEALTH_OK_COUNT" \
      "$STORAGE_HEALTH_WARN_COUNT" \
      "$STORAGE_HEALTH_CRITICAL_COUNT"
  fi

  if [[ "$mode" == "strict" ]] && (( STORAGE_HEALTH_CRITICAL_COUNT > 0 )); then
    return 1
  fi
}

storage_health_main() {
  set -euo pipefail

  local mode="warn"
  local format="text"
  local disk_spec_file=""
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
      --format)
        format="$2"
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
      --disk-spec-file)
        disk_spec_file="$2"
        shift 2
        ;;
      --help|-h)
        cat <<'EOF'
Usage: scripts/helpers/storage-health-common.sh [--mode warn|strict] [--format text|json] [--since "<journalctl window>"] [--disk-spec-file path] label=/dev/disk/by-id/...
EOF
        return 0
        ;;
      *)
        specs+=("$1")
        shift
        ;;
    esac
  done

  if [[ -n "$disk_spec_file" ]]; then
    STORAGE_HEALTH_SPEC_FILE="$disk_spec_file"
    export STORAGE_HEALTH_SPEC_FILE
  fi

  if [[ -z "$disk_spec_file" && ${#specs[@]} -eq 0 ]]; then
    echo "No devices supplied." >&2
    return 1
  fi

  STORAGE_HEALTH_OUTPUT_FORMAT="$format"
  storage_health_check "$mode" "${specs[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  storage_health_main "$@"
fi
