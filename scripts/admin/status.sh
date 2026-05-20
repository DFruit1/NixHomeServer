#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

usage() {
  cat <<'EOF'
Usage: scripts/admin/status.sh [--host <site-or-hostname>] [--target <user@host>] [--refresh] [--format text|json]

Run runtime readiness locally or from a remote host over SSH and summarize the
current result. --refresh is accepted for compatibility; status is always live.
EOF
}

host=""
target=""
output_format="text"

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

if [[ -n "$target" ]]; then
  remote_repo_root="$(printf '%q' "$repo_root")"
  if ! report_json="$(ssh "$target" "cd ${remote_repo_root} && sudo bash scripts/check-runtime-readiness.sh --profile manual --format json")"; then
    echo "blocked: runtime readiness failed on ${target}" >&2
    exit 1
  fi
else
  if ! report_json="$(sudo bash scripts/check-runtime-readiness.sh --profile manual --format json)"; then
    echo "blocked: local runtime readiness failed" >&2
    exit 1
  fi
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
  "- severity: \(.overallSeverity // "unknown")",
  "- zfs: \(.zfs.runtimeState // "unknown")",
  "- smart disks: \((.smart // []) | length)"
' <<<"$report_json"
echo

echo "Failed or warning items"
{
  jq -r '.units[]? | select(.severity != "OK") | "- unit \(.unit): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.edgeHttp[]? | select(.severity != "OK") | "- edge \(.name): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.internalHttp[]? | select(.severity != "OK") | "- internal \(.name): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.dns[]? | select(.severity != "OK") | "- dns \(.host): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.mounts[]? | select(.severity != "OK") | "- mount \(.target): \(.severity) (\(.detail))"' <<<"$report_json"
  jq -r '.smart[]? | select(.severity != "OK") | "- disk \(.label): \(.severity) (\(.detail))"' <<<"$report_json"
} | sed '/^$/d' || true

echo
echo "Next commands"
echo "  nix run .#admin -- status --host ${host}"
echo "  sudo ./scripts/check-runtime-readiness.sh --profile manual --deep"
echo "  sudo systemctl status storage-smart-short.timer"
echo "  sudo systemctl status storage-smart-long.timer"
