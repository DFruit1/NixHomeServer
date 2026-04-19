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
mkdir -p "$state_dir" "$bin_dir" "$dev_dir" "$mount_root/data" "$mount_root/disk1" "$mount_root/parity" "$mount_root/backup" "$mount_root/cold-storage"
touch "$dev_dir/clean" "$dev_dir/aging" "$dev_dir/backup"

cat >"$config_file" <<EOF
{
  "hostname": "server",
  "mergerfsMount": "${mount_root}/data",
  "dataMounts": ["${mount_root}/disk1"],
  "parityMounts": ["${mount_root}/parity"],
  "disks": [
    { "label": "disk1", "device": "${dev_dir}/clean" },
    { "label": "parity", "device": "${dev_dir}/aging" },
    { "label": "backupDisk", "device": "${dev_dir}/backup" }
  ],
  "backup": {
    "expected": true,
    "mountPoint": "${mount_root}/backup",
    "device": "${dev_dir}/backup"
  },
  "coldStorage": {
    "monitored": false,
    "mountPoint": "${mount_root}/cold-storage",
    "device": "${dev_dir}/cold-storage"
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

cat >"$bin_dir/snapraid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

case "$1" in
  status)
    cat "$STORAGE_MONITORING_SNAPRAID_STATUS_FIXTURE"
    ;;
  diff)
    cat "$STORAGE_MONITORING_SNAPRAID_DIFF_FIXTURE"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$bin_dir/snapraid"

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
${mount_root}/data=fuse.mergerfs
${mount_root}/disk1=xfs
${mount_root}/parity=xfs
${mount_root}/backup=xfs
EOF

cat >"$tmpdir/systemctl.clean" <<'EOF'
snapraid-sync.timer|active|enabled
snapraid-scrub.timer|active|enabled
storage-health-report.timer|active|enabled
storage-smart-short@disk1.timer|active|enabled
storage-smart-long@disk1.timer|active|enabled
storage-smart-short@parity.timer|active|enabled
storage-smart-long@parity.timer|active|enabled
storage-smart-short@backupDisk.timer|active|enabled
storage-smart-long@backupDisk.timer|active|enabled
EOF

cat >"$tmpdir/snapraid-status.clean" <<'EOF'
No error detected.
EOF

cat >"$tmpdir/snapraid-diff.clean" <<'EOF'
 100 equal
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
    STORAGE_MONITORING_SNAPRAID_STATUS_FIXTURE="$tmpdir/snapraid-status.clean" \
    STORAGE_MONITORING_SNAPRAID_DIFF_FIXTURE="$tmpdir/snapraid-diff.clean" \
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
require_json_equal "$(jq -r '.coldStorage.monitored' "$state_dir/latest.json")" 'false' \
  "Cold storage must stay excluded from automated monitoring."

echo "ℹ️ Checking alert de-duplication…"
curl_log_dedupe="${tmpdir}/curl.dedupe.log"
run_report "$config_file" "$curl_log_dedupe"
dedupe_bytes="0"
if [[ -f "$curl_log_dedupe" ]]; then
  dedupe_bytes="$(wc -c <"$curl_log_dedupe" | tr -d '[:space:]')"
fi
require_json_equal "$dedupe_bytes" "0" \
  "An unchanged degraded state must not resend the same ntfy alert."

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
  STORAGE_MONITORING_SNAPRAID_STATUS_FIXTURE="$tmpdir/snapraid-status.clean" \
  STORAGE_MONITORING_SNAPRAID_DIFF_FIXTURE="$tmpdir/snapraid-diff.clean" \
  STORAGE_MONITORING_JOURNAL_FIXTURE="$TESTS_REPO_ROOT/tests/fixtures/storage-health/transport.journal" \
  STORAGE_ALERT_WEBHOOK_FILE="$tmpdir/webhook-url" \
  STORAGE_MONITORING_CURL_LOG="${tmpdir}/curl.critical.log" \
  scripts/storage-health-report.sh
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" 'CRITICAL' \
  "Recent transport errors must escalate the report to CRITICAL."

echo "✅ Storage monitoring tests passed."
