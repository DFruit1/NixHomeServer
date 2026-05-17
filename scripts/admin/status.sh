#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/status.sh [--host <site-or-hostname>] [--target <user@host>] [--refresh] [--format text|json]

Summarize /var/lib/system-health-monitoring/latest.json locally or from a
remote host over SSH.
EOF
}

host=""
target=""
refresh=false
output_format="text"
report_path="/var/lib/system-health-monitoring/latest.json"

while (($# > 0)); do
  case "$1" in
    --host)
      host="${2:-}"
      shift 2
      ;;
    --target)
      target="${2:-}"
      shift 2
      ;;
    --refresh)
      refresh=true
      shift
      ;;
    --format)
      output_format="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

case "$output_format" in
  text|json) ;;
  *)
    echo "blocked: --format must be text or json" >&2
    exit 1
    ;;
esac

if [[ -z "$host" ]]; then
  host="$(default_host)"
fi

need jq
if [[ -n "$target" ]]; then
  need ssh
fi

if [[ "$refresh" == true ]]; then
  if [[ -n "$target" ]]; then
    ssh "$target" "sudo systemctl start system-health-report.service"
  else
    sudo systemctl start system-health-report.service
  fi
fi

if [[ -n "$target" ]]; then
  report_json="$(ssh "$target" "sudo cat '$report_path'")"
else
  report_json="$(cat "$report_path")"
fi

if [[ "$output_format" == "json" ]]; then
  jq '.' <<<"$report_json"
  exit 0
fi

echo "NixHomeServer status"
echo "host: ${host}"
echo "timestamp: $(jq -r '.timestamp // "unknown"' <<<"$report_json")"
echo "overall: $(jq -r '.overallSeverity // "unknown"' <<<"$report_json")"
echo

echo "Runtime"
jq -r '
  "- severity: \(.runtime.overallSeverity // "unknown")",
  "- backup: \(.runtime.backup.severity // "unknown") (\(.runtime.backup.detail // "no detail"))",
  "- zfs: \(.runtime.zfs.runtimeState // "unknown")"
' <<<"$report_json"
echo

echo "Storage"
jq -r '
  "- severity: \(.storage.overallSeverity // "unknown")",
  "- pool: \(.storage.zfs.statusSeverity // "unknown") (\(.storage.zfs.statusSummary // "unknown"))",
  "- restore verification: \(.storage.restoreVerification.overallSeverity // "unknown")"
' <<<"$report_json"
echo

echo "Failed or warning items"
{
  jq -r '.runtime.units[]? | select(.severity != "OK") | "- unit \(.unit): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.runtime.edgeHttp[]? | select(.severity != "OK") | "- edge \(.name): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.runtime.internalHttp[]? | select(.severity != "OK") | "- internal \(.name): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.runtime.dns[]? | select(.severity != "OK") | "- dns \(.host): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.storage.disks[]? | select(.severity != "OK") | "- disk \(.label): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.storage.mounts[]? | select(.severity != "OK") | "- mount \(.target): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.storage.alerts[]? | "- alert: " + .' <<<"$report_json"
} | sed '/^$/d' || true

echo
echo "Next commands"
echo "  nix run .#admin -- status --host ${host} --refresh"
echo "  sudo ./scripts/check-runtime-readiness.sh --profile manual --deep"
echo "  sudo systemctl status system-health-report.service"
echo "  sudo systemctl status system-state-restore-verify.service"
