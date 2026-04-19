#!/usr/bin/env bash

set -euo pipefail

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

need jq curl sha256sum

if (($# != 2)); then
  echo "Usage: scripts/storage-alert-send.sh <report-json> <report-txt>" >&2
  exit 1
fi

report_json="$1"
report_txt="$2"
state_dir="${STORAGE_MONITORING_STATE_DIR:-/var/lib/storage-monitoring}"
webhook_file="${STORAGE_ALERT_WEBHOOK_FILE:-}"
digest_file="${state_dir}/last-alert-digest"
severity_file="${state_dir}/last-alert-severity"

mkdir -p "$state_dir"

if [[ ! -f "$report_json" || ! -f "$report_txt" ]]; then
  echo "❌ Missing report artifacts for alert dispatch." >&2
  exit 1
fi

if [[ -z "$webhook_file" || ! -r "$webhook_file" ]]; then
  echo "ℹ️ Storage alerts disabled: webhook secret is unavailable." >&2
  exit 0
fi

webhook_url="$(tr -d '\r\n' <"$webhook_file")"
if [[ -z "$webhook_url" || "$webhook_url" == REPLACE_ME* ]]; then
  echo "ℹ️ Storage alerts disabled: webhook secret is still a placeholder." >&2
  exit 0
fi

hostname="$(jq -r '.hostname' "$report_json")"
severity="$(jq -r '.overallSeverity' "$report_json")"
previous_digest="$(cat "$digest_file" 2>/dev/null || true)"
previous_severity="$(cat "$severity_file" 2>/dev/null || true)"
normalized_digest="$(
  jq -c '{
    overallSeverity,
    alerts,
    degradedDisks: [.disks[] | select(.severity != "OK") | {label, severity, detail}],
    unhealthyMounts: [.mounts[] | select(.severity != "OK") | {target, severity, detail}],
    snapraid: {
      statusSeverity: .snapraid.statusSeverity,
      diffSeverity: .snapraid.diffSeverity,
      statusSummary: .snapraid.statusSummary
    },
    backup: .backup
  }' "$report_json" | sha256sum | awk '{print $1}'
)"

send_ntfy() {
  local title="$1"
  local priority="$2"
  local tags="$3"
  local body="$4"

  curl -fsS --retry 3 \
    -H "Title: ${title}" \
    -H "Priority: ${priority}" \
    -H "Tags: ${tags}" \
    --data-binary @- \
    "$webhook_url" <<<"$body"
}

if [[ "$severity" == "OK" ]]; then
  if [[ -n "$previous_severity" && "$previous_severity" != "OK" ]]; then
    recovery_body="$(
      printf 'Host: %s\nSeverity: OK\nRecovery: storage monitoring returned to healthy state.\nReport: %s\n' \
        "$hostname" "$report_txt"
    )"
    send_ntfy "${hostname}: storage recovered" "default" "white_check_mark,storage" "$recovery_body"
  fi
  printf 'OK\n' >"$severity_file"
  printf '%s\n' "$normalized_digest" >"$digest_file"
  exit 0
fi

if [[ "$normalized_digest" == "$previous_digest" ]]; then
  printf '%s\n' "$severity" >"$severity_file"
  exit 0
fi

priority="default"
tags="warning,storage"
if [[ "$severity" == "CRITICAL" ]]; then
  priority="high"
  tags="rotating_light,warning,storage"
fi

body="$(
  jq -r --arg reportTxt "$report_txt" '
    [
      "Host: " + .hostname,
      "Severity: " + .overallSeverity,
      "SnapRAID: " + .snapraid.statusSummary,
      "Report: " + $reportTxt,
      "Top findings:"
    ]
    + ((.alerts | .[0:3]) | map("- " + .))
    | join("\n")
  ' "$report_json"
)"

send_ntfy "${hostname}: storage ${severity,,}" "$priority" "$tags" "$body"
printf '%s\n' "$normalized_digest" >"$digest_file"
printf '%s\n' "$severity" >"$severity_file"
