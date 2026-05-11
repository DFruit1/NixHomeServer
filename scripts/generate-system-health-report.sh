#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
source "$script_dir/helpers/runtime-health-common.sh"
init_repo_root "SYSTEM_HEALTH_MONITORING_REPO_ROOT"
cd_repo_root
source "$repo_root/scripts/helpers/storage-health-common.sh"
ensure_default_nix_config

alert_send_script="${SYSTEM_HEALTH_MONITORING_ALERT_SEND_SCRIPT:-$repo_root/scripts/helpers/send-storage-health-alert.sh}"
readiness_script="${SYSTEM_HEALTH_MONITORING_READINESS_SCRIPT:-$repo_root/scripts/check-runtime-readiness.sh}"

load_config_json() {
  if [[ -n "${SYSTEM_HEALTH_MONITORING_CONFIG_JSON_FILE:-}" ]]; then
    cat "$SYSTEM_HEALTH_MONITORING_CONFIG_JSON_FILE"
  else
    runtime_health_load_snapshot
    jq '{
      hostname: .host.hostname,
      systemDisk: .storage.systemDisk,
      dataPool: .storage.dataPool
    }' <<<"$RUNTIME_HEALTH_SNAPSHOT"
  fi
}

check_mount_json() {
  runtime_health_check_mount_json "$@"
}

timer_state_json() {
  runtime_health_timer_state_json "$@"
}

append_lines() {
  local file="$1"
  shift
  for line in "$@"; do
    printf '%s\n' "$line" >>"$file"
  done
}

need nix jq findmnt smartctl journalctl systemctl sha256sum zpool zfs getent

config_json="$(load_config_json)"
state_dir="${SYSTEM_HEALTH_MONITORING_STATE_DIR:-/var/lib/system-health-monitoring}"
history_dir="${state_dir}/history"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp_file="$(date -u +%Y%m%dT%H%M%S%NZ)"
latest_json="${state_dir}/latest.json"
latest_txt="${state_dir}/latest.txt"
history_json="${history_dir}/${stamp_file}.json"
history_txt="${history_dir}/${stamp_file}.txt"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
discovery_json_file="${tmpdir}/storage-discovery.json"
disk_specs_file="${tmpdir}/smart-disk-specs.json"

mkdir -p "$state_dir" "$history_dir"

hostname="$(jq -r '.hostname' <<<"$config_json")"
data_pool_name="$(jq -r '.dataPool.name' <<<"$config_json")"

mounts_file="${tmpdir}/mounts.jsonl"
timers_file="${tmpdir}/timers.jsonl"
alerts_file="${tmpdir}/alerts.txt"
runtime_json_file="${tmpdir}/runtime.json"
: >"$alerts_file"

runtime_status=0
if bash "$readiness_script" --profile monitor --format json >"$runtime_json_file"; then
  runtime_status=0
else
  runtime_status=$?
fi
runtime_json="$(jq -c '.' "$runtime_json_file" 2>/dev/null || true)"
if [[ -z "$runtime_json" ]]; then
  runtime_json="$(
    jq -cn \
      --arg timestamp "$timestamp" \
      --arg hostname "$(jq -r '.hostname' <<<"$config_json")" \
      --arg detail "runtime readiness did not produce valid JSON output" \
      --argjson exitStatus "$runtime_status" '
        {
          timestamp: $timestamp,
          profile: "monitor",
          hostname: $hostname,
          overallSeverity: "CRITICAL",
          units: [],
          edgeHttp: [],
          internalHttp: [],
          dns: [],
          mounts: [],
          appState: [],
          requiredPaths: [],
          persistence: [],
          backup: {
            severity: "CRITICAL",
            detail: $detail
          },
          smart: [],
          zfs: {
            statusSeverity: "CRITICAL",
            statusSummary: "runtime check failed",
            datasetSeverity: "CRITICAL",
            datasetSummary: $detail,
            runtimeState: "failed"
          },
          deepChecks: [],
          accessChecks: {
            matrix: [],
            localUnauth: [],
            authed: [],
            vaultwarden: {
              status: "error",
              detail: $detail
            }
          },
          warnings: [
            ("runtime readiness exited before returning JSON (status " + ($exitStatus | tostring) + ")")
          ]
        }
      '
  )"
fi
runtime_severity="$(jq -r '.overallSeverity' <<<"$runtime_json")"
hostname="$(jq -r '.hostname // empty' <<<"$runtime_json")"
if [[ -z "$hostname" || "$hostname" == "null" ]]; then
  hostname="$(jq -r '.hostname' <<<"$config_json")"
fi

check_mount_json "dataPool" "$(jq -r '.dataPool.mountPoint' <<<"$config_json")" "zfs" >>"$mounts_file"
while IFS= read -r mount; do
  label="$(basename "$mount")"
  check_mount_json "$label" "$mount" "zfs" >>"$mounts_file"
done < <(jq -r '.dataPool.datasetMounts[]' <<<"$config_json")

discovery_args=(--format json)
if [[ -n "${SYSTEM_HEALTH_MONITORING_CONFIG_JSON_FILE:-}" ]]; then
  discovery_args+=(--config-json-file "$SYSTEM_HEALTH_MONITORING_CONFIG_JSON_FILE")
fi
bash "$repo_root/scripts/discover-storage-devices.sh" "${discovery_args[@]}" >"$discovery_json_file"
jq '.allSmartDisks' "$discovery_json_file" >"$disk_specs_file"
smart_json="$(bash "$repo_root/scripts/helpers/storage-health-common.sh" --mode warn --format json --disk-spec-file "$disk_specs_file")"

mounts_ok=true
if jq -e 'select(.severity != "OK")' "$mounts_file" >/dev/null 2>&1; then
  mounts_ok=false
fi

zpool_health="$(
  zpool list -H -o health "$data_pool_name" 2>/dev/null || true
)"
if [[ "$zpool_health" == "ONLINE" ]]; then
  zpool_status_severity="OK"
  zpool_status_summary="ONLINE"
  zfs_health_state="ONLINE"
elif [[ "$zpool_health" == "DEGRADED" ]]; then
  zpool_status_severity="CRITICAL"
  zpool_status_summary="DEGRADED"
  zfs_health_state="DEGRADED"
  echo "ZFS pool health for ${data_pool_name}: ${zpool_health}" >>"$alerts_file"
elif [[ -n "$zpool_health" ]]; then
  zpool_status_severity="CRITICAL"
  zpool_status_summary="$zpool_health"
  zfs_health_state="$zpool_health"
  echo "ZFS pool health for ${data_pool_name}: ${zpool_health}" >>"$alerts_file"
else
  zpool_status_severity="CRITICAL"
  zpool_status_summary="pool missing"
  zfs_health_state="pool missing"
  echo "ZFS pool ${data_pool_name} is not importable." >>"$alerts_file"
fi

zfs_dataset_output="$(
  zfs list -H -r -o name,mountpoint "$data_pool_name" 2>/dev/null || true
)"
zfs_dataset_severity="OK"
zfs_dataset_summary="expected datasets listed"
while IFS= read -r mount; do
  [[ -n "$mount" ]] || continue
  if ! grep -Fq "$mount" <<<"$zfs_dataset_output"; then
    zfs_dataset_severity="CRITICAL"
    zfs_dataset_summary="missing expected dataset mounts"
    echo "Missing expected ZFS dataset mount in zfs list output: ${mount}" >>"$alerts_file"
  fi
done < <(jq -r '.dataPool.datasetMounts[]' <<<"$config_json")

if [[ "$zfs_health_state" == "ONLINE" && "$mounts_ok" == true && "$zfs_dataset_severity" == "OK" ]]; then
  zfs_runtime_state="operational"
elif [[ "$zfs_health_state" == "DEGRADED" && "$mounts_ok" == true && "$zfs_dataset_severity" == "OK" ]]; then
  zfs_runtime_state="degraded"
else
  zfs_runtime_state="failed"
fi

append_lines "$timers_file" \
  "$(timer_state_json "system-health-report.timer")"
append_lines "$timers_file" \
  "$(timer_state_json "storage-smart-short.timer")" \
  "$(timer_state_json "storage-smart-long.timer")"

while IFS= read -r line; do
  echo "$line" >>"$alerts_file"
done < <(jq -r '.disks[] | select(.severity != "OK") | "\(.label): \(.detail)"' <<<"$smart_json")
while IFS= read -r line; do
  echo "$line" >>"$alerts_file"
done < <(jq -r 'select(.severity != "OK") | "\(.target): \(.detail)"' "$mounts_file")
while IFS= read -r line; do
  echo "$line" >>"$alerts_file"
done < <(jq -r 'select(.severity != "OK") | "\(.unit): \(.detail)"' "$timers_file")

mounts_json="$(jq -s '.' "$mounts_file")"
timers_json="$(jq -s '.' "$timers_file")"
alerts_json="$(sort -u "$alerts_file" | sed '/^$/d' | jq -R . | jq -s '.')"
zfs_json="$(runtime_health_zfs_status_json "$zpool_status_summary" "$zpool_status_severity" "$zfs_dataset_summary" "$zfs_dataset_severity" "$zfs_health_state" "$zfs_runtime_state")"

storage_overall_severity="$(
  jq -nr \
    --argjson smart "$smart_json" \
    --argjson mounts "$mounts_json" \
    --argjson timers "$timers_json" \
    --argjson zfsStatus "$zfs_json" \
    '
      def escalate($current; $next):
        if $current == "CRITICAL" or $next == "CRITICAL" then "CRITICAL"
        elif $current == "WARN" or $next == "WARN" then "WARN"
        else "OK"
        end;

      reduce (
        ($smart.disks | map(.severity))
        + ($mounts | map(.severity))
        + ($timers | map(.severity))
        + [$zfsStatus.statusSeverity, $zfsStatus.datasetSeverity]
      )[] as $severity ("OK"; escalate(.; $severity))
    '
)"

grouped_disks="$(
  jq '
    {
      system: [ .disks[] | select(.group == "system") ],
      zfsData: [ .disks[] | select(.group == "zfs-data") ],
      other: [ .disks[] | select(.group == "other") ]
    }
  ' <<<"$smart_json"
)"

storage_json="$(
  jq -n \
    --arg overallSeverity "$storage_overall_severity" \
    --argjson disks "$smart_json" \
    --argjson groupedDisks "$grouped_disks" \
    --argjson mounts "$mounts_json" \
    --argjson timers "$timers_json" \
    --argjson zfsStatus "$zfs_json" \
    --argjson alerts "$alerts_json" '
      {
        overallSeverity: $overallSeverity,
        disks: $disks.disks,
        groupedDisks: $groupedDisks,
        mounts: $mounts,
        selfTests: ($disks.disks | map({
          label,
          device,
          severity,
          lastSelfTestStatus
        })),
        timers: $timers,
        zfs: $zfsStatus,
        alerts: $alerts
      }
    '
)"

overall_severity="$(
  jq -nr \
    --arg runtimeSeverity "$runtime_severity" \
    --arg storageSeverity "$storage_overall_severity" \
    '
      def escalate($current; $next):
        if $current == "CRITICAL" or $next == "CRITICAL" then "CRITICAL"
        elif $current == "WARN" or $next == "WARN" then "WARN"
        else "OK"
        end;
      reduce [$runtimeSeverity, $storageSeverity][] as $severity ("OK"; escalate(.; $severity))
    '
)"

report_json_payload="$(
  jq -n \
    --arg timestamp "$timestamp" \
    --arg hostname "$hostname" \
    --arg overallSeverity "$overall_severity" \
    --argjson runtime "$runtime_json" \
    --argjson storage "$storage_json" '
      {
        timestamp: $timestamp,
        hostname: $hostname,
        overallSeverity: $overallSeverity,
        runtime: $runtime,
        storage: $storage
      }
    '
)"

printf '%s\n' "$report_json_payload" | jq '.' >"$latest_json"
cp "$latest_json" "$history_json"

{
  echo "System Health Report"
  echo "Timestamp: $timestamp"
  echo "Host: $hostname"
  echo "Overall severity: $overall_severity"
  echo
  echo "Runtime:"
  jq -r '"- profile: \(.runtime.profile)\n- severity: \(.runtime.overallSeverity)\n- zfs runtime: \(.runtime.zfs.runtimeState)\n- backup: \(.runtime.backup.severity) (\(.runtime.backup.detail))"' "$latest_json"
  echo
  echo "Storage:"
  jq -r '"- severity: \(.storage.overallSeverity)\n- pool: \(.storage.zfs.statusSeverity) (\(.storage.zfs.statusSummary))\n- runtime: \(.storage.zfs.runtimeState)\n- datasets: \(.storage.zfs.datasetSeverity) (\(.storage.zfs.datasetSummary))"' "$latest_json"
  echo
  echo "Mounts:"
  jq -r '.storage.mounts[] | "- \(.label) \(.target): \(.severity) (\(.detail))"' "$latest_json"
  echo
  echo "Disks:"
  jq -r '.storage.disks[] | "- \(.label) \(.severity): \(.detail) [self-test=\(.lastSelfTestStatus)]"' "$latest_json"
  echo
  echo "Timers:"
  jq -r '.storage.timers[] | "- \(.unit): \(.severity) (\(.detail))"' "$latest_json"
  echo
  echo "Alerts:"
  jq -r 'if (.storage.alerts | length) == 0 then "- none" else (.storage.alerts[] | "- " + .) end' "$latest_json"
  echo
  echo "Artifacts:"
  echo "- JSON: $latest_json"
  echo "- Text: $latest_txt"
} >"$latest_txt"
cp "$latest_txt" "$history_txt"

bash "$alert_send_script" "$latest_json" "$latest_txt"
exit "$runtime_status"
