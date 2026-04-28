#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root "STORAGE_MONITORING_REPO_ROOT"
alert_send_script="${STORAGE_MONITORING_ALERT_SEND_SCRIPT:-$repo_root/scripts/storage-alert-send.sh}"
cd_repo_root
source "$repo_root/scripts/lib-storage-health.sh"
ensure_default_nix_config

load_config_json() {
  if [[ -n "${STORAGE_MONITORING_CONFIG_JSON_FILE:-}" ]]; then
    cat "$STORAGE_MONITORING_CONFIG_JSON_FILE"
  else
    local nix_expr
    nix_expr="$(cat <<'EOF'
      let
        flake = builtins.getFlake (toString __REPO_ROOT__);
        lib = flake.inputs.nixpkgs.lib;
        vars = import __REPO_ROOT__/vars.nix { inherit lib; };
        cfg = (builtins.getAttr vars.hostname flake.nixosConfigurations).config;
        dataLabels = builtins.genList (idx: "disk${toString (idx + 1)}") (builtins.length vars.monitoredDataDiskIds);
        coldLabels = map (pool: pool.name) vars.coldStoragePools;
        labels = dataLabels ++ coldLabels;
        diskIds = vars.monitoredDataDiskIds ++ vars.monitoredColdStorageDiskIds;
        mkDisk = idx: {
          label = builtins.elemAt labels idx;
          device = "/dev/disk/by-id/${builtins.elemAt diskIds idx}";
        };
      in
      {
        hostname = vars.hostname;
        dataPool = {
          name = vars.zfsDataPool.name;
          mountPoint = vars.zfsDataPool.mountPoint;
          datasetMounts = map (dataset: "${vars.zfsDataPool.mountPoint}/${dataset}") vars.zfsDataPool.datasets;
        };
        disks = builtins.genList mkDisk (builtins.length diskIds);
        coldStorage = {
          pools = map (pool: {
            name = pool.name;
            mountPoint = pool.mountPoint;
            device = "/dev/disk/by-id/${pool.disk}";
            monitored = true;
          }) vars.coldStoragePools;
        };
      }
EOF
)"
    nix_expr="${nix_expr//__REPO_ROOT__/${repo_root}}"
    nix eval --json --impure --expr "$nix_expr"
  fi
}

mount_result_json() {
  jq -nc \
    --arg label "$1" \
    --arg target "$2" \
    --arg expectedFstype "$3" \
    --arg actualFstype "$4" \
    --arg severity "$5" \
    --arg detail "$6" \
    --argjson present "$7" \
    '{
      label: $label,
      target: $target,
      expectedFstype: $expectedFstype,
      actualFstype: $actualFstype,
      present: $present,
      severity: $severity,
      detail: $detail
    }'
}

timer_result_json() {
  jq -nc \
    --arg unit "$1" \
    --arg activeState "$2" \
    --arg enabledState "$3" \
    --arg severity "$4" \
    --arg detail "$5" \
    '{
      unit: $unit,
      activeState: $activeState,
      enabledState: $enabledState,
      severity: $severity,
      detail: $detail
    }'
}

check_mount_json() {
  local label="$1"
  local target="$2"
  local expected_fstype="$3"
  local actual_fstype severity detail present access_output

  actual_fstype="$(findmnt -nro FSTYPE "$target" 2>/dev/null || true)"
  if [[ "$actual_fstype" == "$expected_fstype" ]]; then
    if access_output="$(ls -d "$target" 2>&1 >/dev/null)"; then
      severity="OK"
      detail="mounted and accessible"
      present=true
    else
      severity="CRITICAL"
      detail="mounted but inaccessible: ${access_output//$'\n'/ }"
      present=false
    fi
  else
    severity="CRITICAL"
    detail="expected ${expected_fstype}, got ${actual_fstype:-missing}"
    present=false
  fi

  mount_result_json "$label" "$target" "$expected_fstype" "$actual_fstype" "$severity" "$detail" "$present"
}

timer_state_json() {
  local unit="$1"
  local active_state enabled_state severity detail

  active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  severity="OK"
  detail="timer active and enabled"

  if [[ "$active_state" != "active" || "$enabled_state" != "enabled" ]]; then
    severity="WARN"
    detail="active=${active_state:-unknown}, enabled=${enabled_state:-unknown}"
  fi

  timer_result_json "$unit" "$active_state" "$enabled_state" "$severity" "$detail"
}

append_lines() {
  local file="$1"
  shift
  for line in "$@"; do
    printf '%s\n' "$line" >>"$file"
  done
}

zfs_status_json() {
  jq -nc \
    --arg statusSummary "$1" \
    --arg statusSeverity "$2" \
    --arg datasetSummary "$3" \
    --arg datasetSeverity "$4" \
    --arg healthState "$5" \
    --arg runtimeState "$6" \
    '{
      statusSummary: $statusSummary,
      statusSeverity: $statusSeverity,
      datasetSummary: $datasetSummary,
      datasetSeverity: $datasetSeverity,
      healthState: $healthState,
      runtimeState: $runtimeState
    }'
}

need nix jq findmnt smartctl journalctl systemctl sha256sum zpool zfs

config_json="$(load_config_json)"
state_dir="${STORAGE_MONITORING_STATE_DIR:-/var/lib/storage-monitoring}"
history_dir="${state_dir}/history"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp_file="$(date -u +%Y%m%dT%H%M%SZ)"
latest_json="${state_dir}/latest.json"
latest_txt="${state_dir}/latest.txt"
history_json="${history_dir}/${stamp_file}.json"
history_txt="${history_dir}/${stamp_file}.txt"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$state_dir" "$history_dir"

hostname="$(jq -r '.hostname' <<<"$config_json")"
data_pool_name="$(jq -r '.dataPool.name' <<<"$config_json")"

mounts_file="${tmpdir}/mounts.jsonl"
timers_file="${tmpdir}/timers.jsonl"
alerts_file="${tmpdir}/alerts.txt"
: >"$alerts_file"

check_mount_json "dataPool" "$(jq -r '.dataPool.mountPoint' <<<"$config_json")" "zfs" >>"$mounts_file"
while IFS= read -r mount; do
  label="$(basename "$mount")"
  check_mount_json "$label" "$mount" "zfs" >>"$mounts_file"
done < <(jq -r '.dataPool.datasetMounts[]' <<<"$config_json")

mapfile -t smart_specs < <(jq -r '.disks[] | "\(.label)=\(.device)"' <<<"$config_json")
smart_json="$("$repo_root/scripts/lib-storage-health.sh" --mode warn --format json "${smart_specs[@]}")"

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
  "$(timer_state_json "storage-health-report.timer")"
while IFS= read -r label; do
  append_lines "$timers_file" \
    "$(timer_state_json "storage-smart-short@${label}.timer")" \
    "$(timer_state_json "storage-smart-long@${label}.timer")"
done < <(jq -r '.disks[] | .label' <<<"$config_json")

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
zfs_json="$(zfs_status_json "$zpool_status_summary" "$zpool_status_severity" "$zfs_dataset_summary" "$zfs_dataset_severity" "$zfs_health_state" "$zfs_runtime_state")"

overall_severity="$(
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

report_json_payload="$(
  jq -n \
    --arg timestamp "$timestamp" \
    --arg hostname "$hostname" \
    --arg overallSeverity "$overall_severity" \
    --argjson disks "$smart_json" \
    --argjson mounts "$mounts_json" \
    --argjson timers "$timers_json" \
    --argjson zfsStatus "$zfs_json" \
    --argjson alerts "$alerts_json" \
    --argjson coldStorage "$(jq '.coldStorage' <<<"$config_json")" '
      {
        timestamp: $timestamp,
        hostname: $hostname,
        overallSeverity: $overallSeverity,
        disks: $disks.disks,
        mounts: $mounts,
        selfTests: ($disks.disks | map({
          label,
          device,
          severity,
          lastSelfTestStatus
        })),
        timers: $timers,
        zfs: $zfsStatus,
        alerts: $alerts,
        coldStorage: $coldStorage
      }
    '
)"

printf '%s\n' "$report_json_payload" | jq '.' >"$latest_json"
cp "$latest_json" "$history_json"

{
  echo "Storage Monitoring Report"
  echo "Timestamp: $timestamp"
  echo "Host: $hostname"
  echo "Overall severity: $overall_severity"
  echo
  echo "Mounts:"
  jq -r '.mounts[] | "- \(.label) \(.target): \(.severity) (\(.detail))"' "$latest_json"
  echo
  echo "Disks:"
  jq -r '.disks[] | "- \(.label) \(.severity): \(.detail) [self-test=\(.lastSelfTestStatus)]"' "$latest_json"
  echo
  echo "ZFS:"
  jq -r '"- pool: \(.zfs.statusSeverity) (\(.zfs.statusSummary))\n- health-state: \(.zfs.healthState)\n- runtime-state: \(.zfs.runtimeState)\n- datasets: \(.zfs.datasetSeverity) (\(.zfs.datasetSummary))"' "$latest_json"
  echo
  echo "Timers:"
  jq -r '.timers[] | "- \(.unit): \(.severity) (\(.detail))"' "$latest_json"
  echo
  echo "Alerts:"
  jq -r 'if (.alerts | length) == 0 then "- none" else (.alerts[] | "- " + .) end' "$latest_json"
  echo
  echo "Artifacts:"
  echo "- JSON: $latest_json"
  echo "- Text: $latest_txt"
} >"$latest_txt"
cp "$latest_txt" "$history_txt"

bash "$alert_send_script" "$latest_json" "$latest_txt"
