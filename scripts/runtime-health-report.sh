#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root "RUNTIME_HEALTH_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

state_dir="${RUNTIME_HEALTH_STATE_DIR:-/var/lib/runtime-monitoring}"
history_dir="${state_dir}/history"
readiness_script="${RUNTIME_HEALTH_REPORT_READINESS_SCRIPT:-$repo_root/scripts/runtime-readiness.sh}"
timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
stamp_file="$(date -u +%Y%m%dT%H%M%SZ)"
latest_json="${state_dir}/latest.json"
latest_txt="${state_dir}/latest.txt"
history_json="${history_dir}/${stamp_file}.json"
history_txt="${history_dir}/${stamp_file}.txt"

mkdir -p "$state_dir" "$history_dir"

tmp_json="$(mktemp)"
trap 'rm -f "$tmp_json"' EXIT

status=0
if "$readiness_script" --profile monitor --format json >"$tmp_json"; then
  status=0
else
  status=$?
fi

jq '.' "$tmp_json" >"$latest_json"
cp "$latest_json" "$history_json"

{
  echo "Runtime Health Report"
  echo "Timestamp: $timestamp"
  jq -r '"Host: " + .hostname' "$latest_json"
  jq -r '"Profile: " + .profile' "$latest_json"
  jq -r '"Overall severity: " + .overallSeverity' "$latest_json"
  echo
  echo "Units:"
  jq -r 'if (.units | length) == 0 then "- none" else (.units[] | "- \(.unit): \(.severity) (\(.detail))") end' "$latest_json"
  echo
  echo "Edge HTTP:"
  jq -r 'if (.edgeHttp | length) == 0 then "- none" else (.edgeHttp[] | "- \(.name) \(.url): \(.severity) [\(.httpCode)]") end' "$latest_json"
  echo
  echo "Internal HTTP:"
  jq -r 'if (.internalHttp | length) == 0 then "- none" else (.internalHttp[] | "- \(.name) \(.url): \(.severity) [\(.httpCode)]") end' "$latest_json"
  echo
  echo "DNS:"
  jq -r 'if (.dns | length) == 0 then "- none" else (.dns[] | "- \(.kind) \(.host): \(.severity) (\(.detail))") end' "$latest_json"
  echo
  echo "Mounts:"
  jq -r 'if (.mounts | length) == 0 then "- none" else (.mounts[] | "- \(.target): \(.severity) (\(.detail))") end' "$latest_json"
  echo
  echo "Backup:"
  jq -r '"- " + .backup.severity + ": " + .backup.detail' "$latest_json"
  echo
  echo "SMART:"
  jq -r 'if (.smart | length) == 0 then "- none" else (.smart[] | "- \(.label): \(.severity) (\(.detail))") end' "$latest_json"
  echo
  echo "ZFS:"
  jq -r '"- pool: \(.zfs.statusSeverity) (\(.zfs.statusSummary))\n- datasets: \(.zfs.datasetSeverity) (\(.zfs.datasetSummary))\n- runtime: \(.zfs.runtimeState)"' "$latest_json"
} >"$latest_txt"

cp "$latest_txt" "$history_txt"

exit "$status"
