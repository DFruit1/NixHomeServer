#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

config_file="${tmpdir}/config.json"
state_dir="${tmpdir}/state"
bin_dir="${tmpdir}/bin"
dev_dir="${tmpdir}/devices"
mount_root="${tmpdir}/mounts"
mkdir -p "$state_dir" "$bin_dir" "$dev_dir" "$mount_root/data" "$mount_root/data/users" "$mount_root/data/shared" "$mount_root/cold-storage/v1jan8ph"
touch "$dev_dir/clean" "$dev_dir/aging"

cat >"$config_file" <<EOF
{
  "hostname": "server",
  "dataPool": {
    "name": "data",
    "mountPoint": "${mount_root}/data",
    "datasetMounts": ["${mount_root}/data/users", "${mount_root}/data/shared"]
  },
  "disks": [
    { "label": "disk1", "device": "${dev_dir}/clean" },
    { "label": "cold-v1jan8ph", "device": "${dev_dir}/aging" }
  ],
  "coldStorage": {
    "pools": [
      {
        "name": "cold-v1jan8ph",
        "mountPoint": "${mount_root}/cold-storage/v1jan8ph",
        "device": "${dev_dir}/aging",
        "monitored": true
      }
    ]
  }
}
EOF

cat >"$bin_dir/smartctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

device="${!#}"
base="$(basename "$device")"

if [[ "$1" == "-d" && "$2" == "sat" && "$3" == "-t" ]]; then
  echo "Self-test started for $base"
  exit 0
fi

fixture="${STORAGE_MONITORING_FIXTURE_DIR}/${base}.smartctl"
if [[ ! -f "$fixture" ]]; then
  fixture="${STORAGE_MONITORING_FIXTURE_DIR}/clean.smartctl"
fi

cat "$fixture"
EOF
chmod +x "$bin_dir/smartctl"

cat >"$bin_dir/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${STORAGE_MONITORING_JOURNAL_FIXTURE:-}" ]]; then
  cat "$STORAGE_MONITORING_JOURNAL_FIXTURE"
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
done <"${STORAGE_MONITORING_FINDMNT_FIXTURE}"

exit 1
EOF
chmod +x "$bin_dir/findmnt"

cat >"$bin_dir/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="$1"
unit="${2:-}"
state_file="${STORAGE_MONITORING_SYSTEMCTL_FIXTURE}"

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

cat >"$bin_dir/zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "list" && "$2" == "-H" && "$3" == "-o" && "$4" == "health" ]]; then
  echo "${STORAGE_MONITORING_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

if [[ "$1" == "status" ]]; then
  printf 'pool: %s\nstate: %s\n' "$2" "${STORAGE_MONITORING_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

exit 1
EOF
chmod +x "$bin_dir/zpool"

cat >"$bin_dir/zfs" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "list" ]]; then
  cat "$STORAGE_MONITORING_ZFS_LIST_FIXTURE"
  exit 0
fi

exit 1
EOF
chmod +x "$bin_dir/zfs"

cat >"$bin_dir/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf 'CALL %s\n' "$*" >>"${STORAGE_MONITORING_CURL_LOG}"
cat >>"${STORAGE_MONITORING_CURL_LOG}"
EOF
chmod +x "$bin_dir/curl"

cat >"$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

"$@"
EOF
chmod +x "$bin_dir/sudo"

cat >"$tmpdir/findmnt.clean" <<EOF
${mount_root}/data=zfs
${mount_root}/data/users=zfs
${mount_root}/data/shared=zfs
EOF

cat >"$tmpdir/systemctl.clean" <<'EOF'
storage-health-report.timer|active|enabled
storage-smart-short@disk1.timer|active|enabled
storage-smart-long@disk1.timer|active|enabled
storage-smart-short@cold-v1jan8ph.timer|active|enabled
storage-smart-long@cold-v1jan8ph.timer|active|enabled
EOF

cat >"$tmpdir/zfs-list.clean" <<EOF
data	${mount_root}/data
data/users	${mount_root}/data/users
data/shared	${mount_root}/data/shared
EOF

run_report() {
  local config_json="$1"
  local curl_log="$2"

  PATH="$bin_dir:$PATH" \
    STORAGE_MONITORING_REPO_ROOT="$TESTS_REPO_ROOT" \
    STORAGE_MONITORING_CONFIG_JSON_FILE="$config_json" \
    STORAGE_MONITORING_STATE_DIR="$state_dir" \
    STORAGE_MONITORING_FIXTURE_DIR="$TESTS_REPO_ROOT/tests/fixtures/storage-health" \
    STORAGE_MONITORING_FINDMNT_FIXTURE="$tmpdir/findmnt.clean" \
    STORAGE_MONITORING_SYSTEMCTL_FIXTURE="$tmpdir/systemctl.clean" \
    STORAGE_MONITORING_ZPOOL_HEALTH="${STORAGE_MONITORING_ZPOOL_HEALTH:-ONLINE}" \
    STORAGE_MONITORING_ZFS_LIST_FIXTURE="$tmpdir/zfs-list.clean" \
    STORAGE_ALERT_WEBHOOK_FILE="$tmpdir/webhook-url" \
    STORAGE_MONITORING_CURL_LOG="$curl_log" \
    scripts/storage-health-report.sh
}

printf '%s\n' 'https://ntfy.example.test/storage' >"$tmpdir/webhook-url"

echo "ℹ️ Checking clean report generation…"
curl_log_clean="${tmpdir}/curl.clean.log"
run_report "$config_file" "$curl_log_clean"
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'WARN' \
  "Aging SMART fixtures must surface as a warning in the periodic report."
require_json_equal "$(jq -r '.coldStorage.pools[0].monitored' "$state_dir/latest.json")" 'true' \
  "Configured cold-storage pools must stay in automated monitoring."
require_json_equal "$(jq -r '.zfs.statusSeverity' "$state_dir/latest.json")" 'OK' \
  "Healthy ZFS pool state must be reported as OK."
require_json_equal "$(jq -r '.zfs.healthState' "$state_dir/latest.json")" 'ONLINE' \
  "Healthy ZFS pool state must keep the raw ONLINE health value."
require_json_equal "$(jq -r '.zfs.runtimeState' "$state_dir/latest.json")" 'operational' \
  "Healthy ZFS pool state must report an operational runtime."

echo "ℹ️ Checking alert de-duplication…"
curl_log_dedupe="${tmpdir}/curl.dedupe.log"
run_report "$config_file" "$curl_log_dedupe"
dedupe_bytes="0"
if [[ -f "$curl_log_dedupe" ]]; then
  dedupe_bytes="$(wc -c <"$curl_log_dedupe" | tr -d '[:space:]')"
fi
require_json_equal "$dedupe_bytes" "0" \
  "An unchanged degraded state must not resend the same ntfy alert."

echo "ℹ️ Checking degraded pool reporting…"
curl_log_degraded="${tmpdir}/curl.degraded.log"
STORAGE_MONITORING_ZPOOL_HEALTH=DEGRADED run_report "$config_file" "$curl_log_degraded"
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "A degraded ZFS pool must escalate the report to CRITICAL."
require_json_equal "$(jq -r '.zfs.statusSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "A degraded ZFS pool must keep CRITICAL storage severity."
require_json_equal "$(jq -r '.zfs.healthState' "$state_dir/latest.json")" 'DEGRADED' \
  "A degraded ZFS pool must preserve the raw DEGRADED health state."
require_json_equal "$(jq -r '.zfs.runtimeState' "$state_dir/latest.json")" 'degraded' \
  "A degraded ZFS pool must report degraded runtime rather than failed runtime."

echo "ℹ️ Checking critical transport escalation…"
touch "$dev_dir/transport"
cp "$config_file" "$tmpdir/config.transport.json"
jq --arg transportDisk "${dev_dir}/transport" '.disks[1].device = $transportDisk' "$tmpdir/config.transport.json" >"$tmpdir/config.transport.tmp"
mv "$tmpdir/config.transport.tmp" "$tmpdir/config.transport.json"
PATH="$bin_dir:$PATH" \
  STORAGE_MONITORING_REPO_ROOT="$TESTS_REPO_ROOT" \
  STORAGE_MONITORING_CONFIG_JSON_FILE="$tmpdir/config.transport.json" \
  STORAGE_MONITORING_STATE_DIR="$state_dir" \
  STORAGE_MONITORING_FIXTURE_DIR="$TESTS_REPO_ROOT/tests/fixtures/storage-health" \
  STORAGE_MONITORING_FINDMNT_FIXTURE="$tmpdir/findmnt.clean" \
  STORAGE_MONITORING_SYSTEMCTL_FIXTURE="$tmpdir/systemctl.clean" \
  STORAGE_MONITORING_JOURNAL_FIXTURE="$TESTS_REPO_ROOT/tests/fixtures/storage-health/transport.journal" \
  STORAGE_MONITORING_ZPOOL_HEALTH=ONLINE \
  STORAGE_MONITORING_ZFS_LIST_FIXTURE="$tmpdir/zfs-list.clean" \
  STORAGE_ALERT_WEBHOOK_FILE="$tmpdir/webhook-url" \
  STORAGE_MONITORING_CURL_LOG="${tmpdir}/curl.critical.log" \
  scripts/storage-health-report.sh
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "Recent transport errors must escalate the report to CRITICAL."

echo "✅ Storage monitoring tests passed."
