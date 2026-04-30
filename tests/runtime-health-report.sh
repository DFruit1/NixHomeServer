#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp

echo "ℹ️ Checking runtime-health-report wrapper…"
require_fixed scripts/runtime-health-report.sh '--profile monitor --format json' \
  "runtime-health-report.sh must invoke runtime-readiness.sh in monitor JSON mode."
require_fixed scripts/runtime-health-report.sh '/var/lib/runtime-monitoring' \
  "runtime-health-report.sh must default to the runtime-monitoring state directory."

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

state_dir="${tmpdir}/state"
readiness_script="${tmpdir}/readiness.sh"

cat >"$readiness_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cat <<'JSON'
{
  "timestamp": "2026-04-30T00:00:00Z",
  "profile": "monitor",
  "hostname": "server",
  "overallSeverity": "WARN",
  "units": [{ "unit": "copyparty.service", "severity": "OK", "detail": "unit active" }],
  "edgeHttp": [{ "name": "files", "url": "https://files.example.test/", "severity": "OK", "httpCode": "200", "detail": "http 200" }],
  "internalHttp": [],
  "dns": [],
  "mounts": [],
  "appState": [],
  "requiredPaths": [],
  "persistence": [],
  "backup": { "severity": "WARN", "detail": "backup target absent" },
  "smart": [{ "label": "disk1", "severity": "OK", "detail": "SMART healthy" }],
  "zfs": { "statusSeverity": "WARN", "statusSummary": "DEGRADED", "datasetSeverity": "OK", "datasetSummary": "expected datasets listed", "runtimeState": "degraded" },
  "deepChecks": []
}
JSON
EOF
chmod +x "$readiness_script"

RUNTIME_HEALTH_REPO_ROOT="$TESTS_REPO_ROOT" \
  RUNTIME_HEALTH_STATE_DIR="$state_dir" \
  RUNTIME_HEALTH_REPORT_READINESS_SCRIPT="$readiness_script" \
  scripts/runtime-health-report.sh

require_json_equal "$(jq -r '.profile' "$state_dir/latest.json")" "monitor" \
  "runtime-health-report.sh must persist the readiness JSON payload."
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" "WARN" \
  "runtime-health-report.sh must preserve the runtime-health severity."
require_match "$state_dir/latest.txt" '^Runtime Health Report$' \
  "runtime-health-report.sh must render a text summary alongside the JSON payload."

history_count="$(find "$state_dir/history" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')"
require_json_equal "$history_count" "2" \
  "runtime-health-report.sh must archive both JSON and text history artifacts."

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
RUNTIME_HEALTH_REPO_ROOT="$TESTS_REPO_ROOT" \
  RUNTIME_HEALTH_STATE_DIR="$state_dir" \
  RUNTIME_HEALTH_REPORT_READINESS_SCRIPT="$readiness_script" \
  scripts/runtime-health-report.sh >/dev/null 2>&1
status=$?
set -e
require_json_equal "$status" "1" \
  "runtime-health-report.sh must propagate readiness failures."
require_json_equal "$(jq -r '.overallSeverity' "$state_dir/latest.json")" "CRITICAL" \
  "runtime-health-report.sh must still refresh the persisted report on failure."

echo "✅ Runtime health report tests passed."
