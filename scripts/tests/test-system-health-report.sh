#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp rg
fixture_dir="$TESTS_REPO_ROOT/scripts/tests/fixtures/storage-health"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

config_file="${tmpdir}/config.json"
state_dir="${tmpdir}/state"
bin_dir="${tmpdir}/bin"
mount_root="${tmpdir}/mounts"
device_root="${tmpdir}/devices"
dev_disk_root="${tmpdir}/dev-disk"
by_id_dir="${dev_disk_root}/by-id"

system_disk_actual="${device_root}/system-disk"
system_part_actual="${device_root}/system-disk-part1"
data_a_actual="${device_root}/data-a"
data_a_part_actual="${device_root}/data-a-part1"
data_b_actual="${device_root}/data-b"
data_b_part_actual="${device_root}/data-b-part1"
retired_actual="${device_root}/retired-a"
usb_actual="${device_root}/usb-backup"
usb_part_actual="${device_root}/usb-backup-part1"

mkdir -p "$state_dir" "$bin_dir" "$device_root" "$by_id_dir" "$mount_root/data" "$mount_root/data/users" "$mount_root/data/shared"
touch \
  "$system_disk_actual" \
  "$system_part_actual" \
  "$data_a_actual" \
  "$data_a_part_actual" \
  "$data_b_actual" \
  "$data_b_part_actual" \
  "$retired_actual" \
  "$usb_actual" \
  "$usb_part_actual"

ln -s "$system_disk_actual" "$by_id_dir/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"
ln -s "$system_part_actual" "$by_id_dir/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E-part1"
ln -s "$data_a_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV3997N"
ln -s "$data_a_part_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV3997N-part1"
ln -s "$data_b_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV37712"
ln -s "$data_b_part_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV37712-part1"
ln -s "$retired_actual" "$by_id_dir/ata-HGST_HUS726T4TALA6L4_V1JAKPNH"
ln -s "$usb_actual" "$by_id_dir/usb-Samsung_PSSD_T7_S7MLNS0Y711062N"
ln -s "$usb_part_actual" "$by_id_dir/usb-Samsung_PSSD_T7_S7MLNS0Y711062N-part1"

cat >"$config_file" <<EOF
{
  "hostname": "server",
  "systemDisk": {
    "diskId": "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E",
    "device": "${by_id_dir}/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"
  },
  "dataPool": {
    "name": "data",
    "mountPoint": "${mount_root}/data",
    "datasetMounts": ["${mount_root}/data/users", "${mount_root}/data/shared"]
  }
}
EOF

cat >"$bin_dir/smartctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--scan-open" ]]; then
  cat <<'SCAN'
${system_disk_actual} -d sat # system disk
${data_a_actual} -d sat # data disk a
${data_b_actual} -d sat # data disk b
${retired_actual} -d sat # retired internal disk
${usb_actual} -d sntasmedia # usb backup disk
SCAN
  exit 0
fi

device="\${!#}"
actual="\$(readlink -f "\$device" 2>/dev/null || printf '%s' "\$device")"
base="\$(basename "\$actual")"

if [[ "\${1:-}" == "-d" && "\${3:-}" == "-t" ]]; then
  echo "Self-test started for \$base"
  exit 0
fi

fixture="${fixture_dir}/clean.smartctl"
if [[ "\$base" == "retired-a" ]]; then
  fixture="${fixture_dir}/aging.smartctl"
fi

cat "\$fixture"
EOF
chmod +x "$bin_dir/smartctl"

cat >"$bin_dir/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${SYSTEM_HEALTH_MONITORING_JOURNAL_FIXTURE:-}" ]]; then
  cat "$SYSTEM_HEALTH_MONITORING_JOURNAL_FIXTURE"
fi
EOF
chmod +x "$bin_dir/journalctl"

cat >"$bin_dir/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

target="${!#}"
while IFS='=' read -r mount fstype; do
  if [[ "$mount" == "$target" ]]; then
    printf '%s\n' "$fstype"
    exit 0
  fi
done <"${SYSTEM_HEALTH_MONITORING_FINDMNT_FIXTURE}"

exit 1
EOF
chmod +x "$bin_dir/findmnt"

cat >"$bin_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="$1"
unit="${2:-}"
state_file="${SYSTEM_HEALTH_MONITORING_SYSTEMCTL_FIXTURE}"

lookup() {
  local wanted_unit="$1"
  local field="$2"
  awk -F'|' -v wanted_unit="$wanted_unit" -v field="$field" '
    $1 == wanted_unit {
      if (field == "active") {
        print $2
      } else {
        print $3
      }
      exit
    }
  ' "$state_file"
}

case "$cmd" in
  is-active)
    value="$(lookup "$unit" active)"
    printf '%s\n' "${value:-active}"
    ;;
  is-enabled)
    value="$(lookup "$unit" enabled)"
    printf '%s\n' "${value:-enabled}"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$bin_dir/systemctl"

cat >"$bin_dir/zpool" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" == "list" && "\$2" == "-H" && "\$3" == "-o" && "\$4" == "health" ]]; then
  echo "\${SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

if [[ "\$1" == "status" && "\${2:-}" == "-P" ]]; then
  cat <<'STATUS'
  pool: data
 state: \${SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH:-ONLINE}
config:

        NAME                                                     STATE     READ WRITE CKSUM
        data                                                     \${SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH:-ONLINE}       0     0     0
          mirror-0                                               \${SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH:-ONLINE}       0     0     0
            ${by_id_dir}/ata-ST8000VN002-2ZM188_WPV3997N-part1   ONLINE       0     0     0
            ${by_id_dir}/ata-ST8000VN002-2ZM188_WPV37712-part1   ONLINE       0     0     0

errors: No known data errors
STATUS
  exit 0
fi

if [[ "\$1" == "status" ]]; then
  printf 'pool: %s\nstate: %s\n' "\$2" "\${SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

exit 1
EOF
chmod +x "$bin_dir/zpool"

cat >"$bin_dir/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "list" ]]; then
  cat "$SYSTEM_HEALTH_MONITORING_ZFS_LIST_FIXTURE"
  exit 0
fi

exit 1
EOF
chmod +x "$bin_dir/zfs"

cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'CALL %s\n' "$*" >>"${SYSTEM_HEALTH_MONITORING_CURL_LOG}"
cat >>"${SYSTEM_HEALTH_MONITORING_CURL_LOG}"
EOF
chmod +x "$bin_dir/curl"

cat >"$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

"$@"
EOF
chmod +x "$bin_dir/sudo"

cat >"$bin_dir/lsblk" <<EOF
#!/usr/bin/env bash
set -euo pipefail

cat <<'JSON'
{
  "blockdevices": [
    { "path": "${system_disk_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "SK hynix SC401 SATA 256GB", "serial": "EI89QSTDS10309C9E", "fstype": null, "mountpoints": [] },
    { "path": "${system_part_actual}", "type": "part", "pkname": "${system_disk_actual}", "tran": null, "model": null, "serial": null, "fstype": "btrfs", "mountpoints": ["/", "/nix", "/persist"] },
    { "path": "${data_a_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "ST8000VN002-2ZM188", "serial": "WPV3997N", "fstype": null, "mountpoints": [] },
    { "path": "${data_a_part_actual}", "type": "part", "pkname": "${data_a_actual}", "tran": null, "model": null, "serial": null, "fstype": "zfs_member", "mountpoints": [] },
    { "path": "${data_b_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "ST8000VN002-2ZM188", "serial": "WPV37712", "fstype": null, "mountpoints": [] },
    { "path": "${data_b_part_actual}", "type": "part", "pkname": "${data_b_actual}", "tran": null, "model": null, "serial": null, "fstype": "zfs_member", "mountpoints": [] },
    { "path": "${retired_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "HGST HUS726T4TALA6L4", "serial": "V1JAKPNH", "fstype": null, "mountpoints": [] },
    { "path": "${usb_actual}", "type": "disk", "pkname": null, "tran": "usb", "model": "PSSD T7", "serial": "S7MLNS0Y711062N", "fstype": null, "mountpoints": [] },
    { "path": "${usb_part_actual}", "type": "part", "pkname": "${usb_actual}", "tran": null, "model": null, "serial": null, "fstype": "exfat", "mountpoints": [] }
  ]
}
JSON
EOF
chmod +x "$bin_dir/lsblk"

cat >"$tmpdir/readiness.ok.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cat <<'JSON'
{
  "timestamp": "2026-04-30T00:00:00Z",
  "profile": "monitor",
  "hostname": "server",
  "overallSeverity": "OK",
  "units": [{ "unit": "copyparty.service", "severity": "OK", "detail": "unit active" }],
  "edgeHttp": [{ "name": "files", "url": "https://files.example.test/", "severity": "OK", "httpCode": "200", "detail": "http 200" }],
  "internalHttp": [],
  "dns": [],
  "mounts": [],
  "appState": [],
  "requiredPaths": [],
  "persistence": [],
  "backup": { "severity": "OK", "detail": "backup metadata fresh" },
  "smart": [{ "label": "system", "severity": "OK", "detail": "SMART healthy" }],
  "zfs": { "statusSeverity": "OK", "statusSummary": "ONLINE", "datasetSeverity": "OK", "datasetSummary": "expected datasets listed", "runtimeState": "operational" },
  "deepChecks": []
}
JSON
EOF
chmod +x "$tmpdir/readiness.ok.sh"

cat >"$tmpdir/findmnt.clean" <<EOF
${mount_root}/data=zfs
${mount_root}/data/users=zfs
${mount_root}/data/shared=zfs
EOF

cat >"$tmpdir/systemctl.clean" <<'EOF'
system-health-report.timer|active|enabled
storage-smart-short.timer|active|enabled
storage-smart-long.timer|active|enabled
EOF

cat >"$tmpdir/zfs-list.clean" <<EOF
data	${mount_root}/data
data/users	${mount_root}/data/users
data/shared	${mount_root}/data/shared
EOF

run_report() {
  local config_json="$1"
  local curl_log="$2"
  local readiness_script="$3"

  PATH="$bin_dir:$PATH" \
    STORAGE_DEVICE_DISCOVERY_DEV_DISK_ROOT="$dev_disk_root" \
    SYSTEM_HEALTH_MONITORING_REPO_ROOT="$TESTS_REPO_ROOT" \
    SYSTEM_HEALTH_MONITORING_CONFIG_JSON_FILE="$config_json" \
    SYSTEM_HEALTH_MONITORING_STATE_DIR="$state_dir" \
    SYSTEM_HEALTH_MONITORING_FINDMNT_FIXTURE="$tmpdir/findmnt.clean" \
    SYSTEM_HEALTH_MONITORING_SYSTEMCTL_FIXTURE="$tmpdir/systemctl.clean" \
    SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH="${SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH:-ONLINE}" \
    SYSTEM_HEALTH_MONITORING_ZFS_LIST_FIXTURE="$tmpdir/zfs-list.clean" \
    SYSTEM_HEALTH_MONITORING_ALERT_SEND_SCRIPT="$TESTS_REPO_ROOT/scripts/helpers/send-storage-health-alert.sh" \
    SYSTEM_HEALTH_MONITORING_READINESS_SCRIPT="$readiness_script" \
    STORAGE_ALERT_WEBHOOK_FILE="$tmpdir/webhook-url" \
    SYSTEM_HEALTH_MONITORING_CURL_LOG="$curl_log" \
    scripts/generate-system-health-report.sh
}

printf '%s\n' 'https://ntfy.example.test/storage' >"$tmpdir/webhook-url"

echo "ℹ️ Checking clean report generation…"
curl_log_clean="${tmpdir}/curl.clean.log"
run_report "$config_file" "$curl_log_clean" "$tmpdir/readiness.ok.sh"
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'WARN' \
  "Aging SMART fixtures must surface as a warning in the combined periodic report."
require_json_equal "$(jq -r '.runtime.overallSeverity' "$state_dir/latest.json")" 'OK' \
  "The combined report must embed the runtime monitor payload."
require_json_equal "$(jq -r '.storage.groupedDisks.system | length' "$state_dir/latest.json")" '1' \
  "The combined report must keep the system disk in its own monitored group."
require_json_equal "$(jq -r '.storage.groupedDisks.zfsData | length' "$state_dir/latest.json")" '2' \
  "The combined report must list live ZFS pool members separately from other disks."
require_json_equal "$(jq -r '.storage.groupedDisks.other | length' "$state_dir/latest.json")" '2' \
  "The combined report must classify all attached non-system non-pool disks into the other-disk group."
require_json_equal "$(jq -r --arg actual "${usb_actual}" '.storage.groupedDisks.other[] | select(.actualDevice == $actual) | .smartctlArgs | join(" ")' "$state_dir/latest.json")" '-d sntasmedia' \
  "The combined report must preserve discovered SMART transport args for USB disks."
require_json_equal "$(jq -r '.storage.zfs.statusSeverity' "$state_dir/latest.json")" 'OK' \
  "Healthy ZFS pool state must be reported as OK."
require_json_equal "$(jq -r '.storage.zfs.healthState' "$state_dir/latest.json")" 'ONLINE' \
  "Healthy ZFS pool state must keep the raw ONLINE health value."
require_json_equal "$(jq -r '.storage.zfs.runtimeState' "$state_dir/latest.json")" 'operational' \
  "Healthy ZFS pool state must report an operational runtime."

echo "ℹ️ Checking alert de-duplication…"
curl_log_dedupe="${tmpdir}/curl.dedupe.log"
run_report "$config_file" "$curl_log_dedupe" "$tmpdir/readiness.ok.sh"
dedupe_bytes="0"
if [[ -f "$curl_log_dedupe" ]]; then
  dedupe_bytes="$(wc -c <"$curl_log_dedupe" | tr -d '[:space:]')"
fi
require_json_equal "$dedupe_bytes" "0" \
  "An unchanged degraded state must not resend the same storage alert."

echo "ℹ️ Checking degraded pool reporting…"
curl_log_degraded="${tmpdir}/curl.degraded.log"
SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH=DEGRADED run_report "$config_file" "$curl_log_degraded" "$tmpdir/readiness.ok.sh"
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "A degraded ZFS pool must escalate the combined report to CRITICAL."
require_json_equal "$(jq -r '.storage.overallSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "A degraded ZFS pool must keep CRITICAL storage severity."
require_json_equal "$(jq -r '.storage.zfs.healthState' "$state_dir/latest.json")" 'DEGRADED' \
  "A degraded ZFS pool must preserve the raw DEGRADED health state."
require_json_equal "$(jq -r '.storage.zfs.runtimeState' "$state_dir/latest.json")" 'degraded' \
  "A degraded ZFS pool must report degraded runtime rather than failed runtime."

echo "ℹ️ Checking critical transport escalation…"
cat >"${tmpdir}/retired.transport.journal" <<'EOF'
Apr 19 11:02:13 server kernel: retired-a: hardreset failed
EOF
PATH="$bin_dir:$PATH" \
  STORAGE_DEVICE_DISCOVERY_DEV_DISK_ROOT="$dev_disk_root" \
  SYSTEM_HEALTH_MONITORING_REPO_ROOT="$TESTS_REPO_ROOT" \
  SYSTEM_HEALTH_MONITORING_CONFIG_JSON_FILE="$config_file" \
  SYSTEM_HEALTH_MONITORING_STATE_DIR="$state_dir" \
  SYSTEM_HEALTH_MONITORING_FINDMNT_FIXTURE="$tmpdir/findmnt.clean" \
  SYSTEM_HEALTH_MONITORING_SYSTEMCTL_FIXTURE="$tmpdir/systemctl.clean" \
  SYSTEM_HEALTH_MONITORING_JOURNAL_FIXTURE="${tmpdir}/retired.transport.journal" \
  SYSTEM_HEALTH_MONITORING_ZPOOL_HEALTH=ONLINE \
  SYSTEM_HEALTH_MONITORING_ZFS_LIST_FIXTURE="$tmpdir/zfs-list.clean" \
  SYSTEM_HEALTH_MONITORING_ALERT_SEND_SCRIPT="$TESTS_REPO_ROOT/scripts/helpers/send-storage-health-alert.sh" \
  SYSTEM_HEALTH_MONITORING_READINESS_SCRIPT="$tmpdir/readiness.ok.sh" \
  STORAGE_ALERT_WEBHOOK_FILE="$tmpdir/webhook-url" \
  SYSTEM_HEALTH_MONITORING_CURL_LOG="${tmpdir}/curl.critical.log" \
  scripts/generate-system-health-report.sh
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "Recent transport errors must escalate the combined report to CRITICAL."

echo "ℹ️ Checking runtime report persistence and failure propagation…"
readiness_script="${tmpdir}/readiness.fail.sh"

cat >"$readiness_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cat <<'JSON'
{
  "timestamp": "2026-04-30T00:30:00Z",
  "profile": "monitor",
  "hostname": "server",
  "overallSeverity": "CRITICAL",
  "units": [],
  "edgeHttp": [],
  "internalHttp": [],
  "dns": [],
  "mounts": [],
  "appState": [],
  "requiredPaths": [],
  "persistence": [],
  "backup": { "severity": "CRITICAL", "detail": "backup state failed" },
  "smart": [],
  "zfs": { "statusSeverity": "CRITICAL", "statusSummary": "FAULTED", "datasetSeverity": "CRITICAL", "datasetSummary": "missing datasets", "runtimeState": "failed" },
  "deepChecks": []
}
JSON
exit 1
EOF
chmod +x "$readiness_script"

set +e
run_report "$config_file" "${tmpdir}/curl.failure.log" "$readiness_script" >/dev/null 2>&1
status=$?
set -e

require_json_equal "$status" "1" \
  "generate-system-health-report.sh must propagate runtime monitor failures."
require_json_equal "$(jq -r '.runtime.overallSeverity' "$state_dir/latest.json")" "CRITICAL" \
  "generate-system-health-report.sh must still refresh the persisted report on runtime failure."
require_match "$state_dir/latest.txt" '^System Health Report$' \
  "generate-system-health-report.sh must render a text summary alongside the JSON payload."

history_count="$(find "$state_dir/history" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
require_json_equal "$history_count" "10" \
  "generate-system-health-report.sh must archive JSON and text history artifacts for each run."

echo "✅ System health report tests passed."
