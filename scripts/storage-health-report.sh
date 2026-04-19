#!/usr/bin/env bash

set -euo pipefail

repo_root="${STORAGE_MONITORING_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$repo_root"
source "$repo_root/scripts/lib-storage-health.sh"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

nix_json() {
  local expr="$1"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
      dataLabels = builtins.genList (idx: \"disk\${toString (idx + 1)}\") (builtins.length vars.dataDisks);
      parityLabels = builtins.genList (idx: if idx == 0 then \"parity\" else \"parity\${toString (idx + 1)}\") (builtins.length vars.parityDisks);
      backupLabels = if vars.enableBackupDisk && vars.backupDisk != null then [ \"backupDisk\" ] else [ ];
      labels = dataLabels ++ parityLabels ++ backupLabels;
      diskIds = vars.dataDisks ++ vars.parityDisks ++ (if vars.enableBackupDisk && vars.backupDisk != null then [ vars.backupDisk ] else [ ]);
      mkDisk = idx: {
        label = builtins.elemAt labels idx;
        device = \"/dev/disk/by-id/\${builtins.elemAt diskIds idx}\";
      };
    in
      ${expr}
  "
}

load_config_json() {
  if [[ -n "${STORAGE_MONITORING_CONFIG_JSON_FILE:-}" ]]; then
    cat "$STORAGE_MONITORING_CONFIG_JSON_FILE"
  else
    nix_json '
      {
        hostname = vars.hostname;
        mergerfsMount = vars.dataRoot;
        dataMounts = builtins.genList (idx: "/mnt/disk${toString (idx + 1)}") (builtins.length vars.dataDisks);
        parityMounts = builtins.genList (idx: if idx == 0 then "/mnt/parity" else "/mnt/parity${toString (idx + 1)}") (builtins.length vars.parityDisks);
        disks = builtins.genList mkDisk (builtins.length diskIds);
        backup = {
          expected = vars.enableBackupDisk;
          mountPoint = vars.backupMountPoint;
          device = if vars.backupDisk == null then "" else "/dev/disk/by-id/${vars.backupDisk}";
        };
        coldStorage = {
          monitored = false;
          mountPoint = vars.coldStorageMountPoint;
          device = "/dev/disk/by-id/${vars.coldStorageDisk}";
        };
      }
    '
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

need nix jq findmnt smartctl journalctl snapraid systemctl sha256sum

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
backup_expected="$(jq -r '.backup.expected' <<<"$config_json")"
backup_mount_point="$(jq -r '.backup.mountPoint' <<<"$config_json")"
backup_device="$(jq -r '.backup.device' <<<"$config_json")"

mounts_file="${tmpdir}/mounts.jsonl"
timers_file="${tmpdir}/timers.jsonl"
alerts_file="${tmpdir}/alerts.txt"
: >"$alerts_file"

check_mount_json "mergerfs" "$(jq -r '.mergerfsMount' <<<"$config_json")" "fuse.mergerfs" >>"$mounts_file"
while IFS= read -r mount; do
  label="$(basename "$mount")"
  check_mount_json "$label" "$mount" "xfs" >>"$mounts_file"
done < <(jq -r '.dataMounts[]' <<<"$config_json")
while IFS= read -r mount; do
  label="$(basename "$mount")"
  check_mount_json "$label" "$mount" "xfs" >>"$mounts_file"
done < <(jq -r '.parityMounts[]' <<<"$config_json")
if [[ "$backup_expected" == "true" ]]; then
  check_mount_json "backup" "$backup_mount_point" "xfs" >>"$mounts_file"
fi

mapfile -t smart_specs < <(jq -r '.disks[] | "\(.label)=\(.device)"' <<<"$config_json")
smart_json="$("$repo_root/scripts/lib-storage-health.sh" --mode warn --format json "${smart_specs[@]}")"

if [[ "$backup_expected" == "true" && ! -e "$backup_device" ]]; then
  echo "Configured backup disk is enabled but not attached: ${backup_device}" >>"$alerts_file"
fi

array_mounts_ok=true
if jq -e 'select(.label != "backup" and .severity != "OK")' "$mounts_file" >/dev/null 2>&1; then
  array_mounts_ok=false
fi

snapraid_status="skipped because monitored array mounts are unhealthy"
snapraid_status_severity="WARN"
snapraid_diff_summary="skipped because monitored array mounts are unhealthy"
snapraid_diff_severity="WARN"

if [[ "$array_mounts_ok" == "true" ]]; then
  snapraid_status_output="$(snapraid status 2>&1 || true)"
  snapraid_diff_output="$(snapraid diff 2>&1 || true)"

  if grep -Fq "No error detected." <<<"$snapraid_status_output"; then
    snapraid_status="clean"
    snapraid_status_severity="OK"
  else
    snapraid_status="status not clean"
    snapraid_status_severity="CRITICAL"
    echo "SnapRAID status did not report a clean state." >>"$alerts_file"
  fi

  if grep -Fq "There are differences!" <<<"$snapraid_diff_output"; then
    snapraid_diff_summary="pending changes"
    snapraid_diff_severity="WARN"
    echo "SnapRAID diff shows pending changes." >>"$alerts_file"
  elif grep -Eq '^[[:space:]]*[0-9]+ equal' <<<"$snapraid_diff_output"; then
    snapraid_diff_summary="equal"
    snapraid_diff_severity="OK"
  else
    snapraid_diff_summary="unexpected diff summary"
    snapraid_diff_severity="CRITICAL"
    echo "SnapRAID diff did not return an expected summary." >>"$alerts_file"
  fi
fi

append_lines "$timers_file" \
  "$(timer_state_json "snapraid-sync.timer")" \
  "$(timer_state_json "snapraid-scrub.timer")" \
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

if [[ "$backup_expected" == "true" && ! -e "$backup_device" ]]; then
  backup_present=false
else
  backup_present=true
fi

if [[ "$snapraid_status_severity" != "OK" ]]; then
  echo "SnapRAID status severity: ${snapraid_status_severity}" >>"$alerts_file"
fi
if [[ "$snapraid_diff_severity" != "OK" ]]; then
  echo "SnapRAID diff severity: ${snapraid_diff_severity}" >>"$alerts_file"
fi

alerts_json="$(sort -u "$alerts_file" | sed '/^$/d' | jq -R . | jq -s '.')"
mounts_json="$(jq -s '.' "$mounts_file")"
timers_json="$(jq -s '.' "$timers_file")"

overall_severity="$(
  jq -nr \
    --argjson smart "$smart_json" \
    --argjson mounts "$mounts_json" \
    --argjson timers "$timers_json" \
    --arg snapraidStatusSeverity "$snapraid_status_severity" \
    --arg snapraidDiffSeverity "$snapraid_diff_severity" \
    --argjson backupPresent "$backup_present" \
    --argjson backupExpected "$backup_expected" '
      def escalate($current; $next):
        if $current == "CRITICAL" or $next == "CRITICAL" then "CRITICAL"
        elif $current == "WARN" or $next == "WARN" then "WARN"
        else "OK"
        end;

      reduce (
        ($smart.disks | map(.severity))
        + ($mounts | map(.severity))
        + ($timers | map(.severity))
        + [$snapraidStatusSeverity, $snapraidDiffSeverity]
        + [if ($backupExpected and ($backupPresent | not)) then "CRITICAL" else "OK" end]
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
    --arg snapraidStatus "$snapraid_status" \
    --arg snapraidStatusSeverity "$snapraid_status_severity" \
    --arg snapraidDiffSummary "$snapraid_diff_summary" \
    --arg snapraidDiffSeverity "$snapraid_diff_severity" \
    --argjson alerts "$alerts_json" \
    --argjson backupExpected "$backup_expected" \
    --argjson backupPresent "$backup_present" \
    --arg backupMountPoint "$backup_mount_point" \
    --arg backupDevice "$backup_device" \
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
        snapraid: {
          statusSummary: $snapraidStatus,
          statusSeverity: $snapraidStatusSeverity,
          diffSummary: $snapraidDiffSummary,
          diffSeverity: $snapraidDiffSeverity
        },
        backup: {
          expected: $backupExpected,
          present: $backupPresent,
          mountPoint: $backupMountPoint,
          device: $backupDevice
        },
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
  echo "SnapRAID:"
  jq -r '"- status: \(.snapraid.statusSeverity) (\(.snapraid.statusSummary))\n- diff: \(.snapraid.diffSeverity) (\(.snapraid.diffSummary))"' "$latest_json"
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

"$repo_root/scripts/storage-alert-send.sh" "$latest_json" "$latest_txt"
