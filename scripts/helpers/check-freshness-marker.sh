#!/usr/bin/env bash

set -euo pipefail

marker=""
max_age_seconds=""

while (($# > 0)); do
  case "$1" in
    --marker)
      marker="${2:-}"
      shift 2
      ;;
    --max-age-seconds)
      max_age_seconds="${2:-}"
      shift 2
      ;;
    -h|--help)
      echo "Usage: check-freshness-marker.sh --marker PATH --max-age-seconds SECONDS"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

[[ -n "$marker" && -s "$marker" ]] || { echo "Freshness marker is missing or empty: $marker" >&2; exit 1; }
[[ "$max_age_seconds" =~ ^[1-9][0-9]*$ ]] || { echo "--max-age-seconds must be positive" >&2; exit 2; }

jq_bin="${FRESHNESS_MARKER_JQ_BIN:-jq}"
date_bin="${FRESHNESS_MARKER_DATE_BIN:-date}"
schema_version="$($jq_bin -er '.schemaVersion | select(type == "number")' "$marker")" || {
  echo "Freshness marker has no numeric schemaVersion: $marker" >&2
  exit 1
}
if [[ "$schema_version" != 1 ]]; then
  echo "Freshness marker has unsupported schemaVersion: $schema_version" >&2
  exit 1
fi
completed_at="$($jq_bin -er '.completedAt | select(type == "string" and length > 0)' "$marker")" || {
  echo "Freshness marker has no valid completedAt timestamp: $marker" >&2
  exit 1
}
if [[ ! "$completed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$ ]]; then
  echo "Freshness marker has an invalid completedAt timestamp: $completed_at" >&2
  exit 1
fi
completed_epoch="$($date_bin --date "$completed_at" +%s 2>/dev/null)" || {
  echo "Freshness marker has an invalid completedAt timestamp: $completed_at" >&2
  exit 1
}
now_epoch="${FRESHNESS_MARKER_NOW_EPOCH:-$($date_bin +%s)}"
[[ "$now_epoch" =~ ^[0-9]+$ ]] || { echo "Current epoch is invalid: $now_epoch" >&2; exit 1; }
age_seconds=$((now_epoch - completed_epoch))

if ((age_seconds < 0)); then
  echo "Freshness marker completedAt is in the future: $completed_at" >&2
  exit 1
fi
if ((age_seconds > max_age_seconds)); then
  echo "Freshness marker is stale: age=${age_seconds}s maximum=${max_age_seconds}s" >&2
  exit 1
fi

$jq_bin -n \
  --arg completedAt "$completed_at" \
  --argjson completedEpoch "$completed_epoch" \
  --argjson ageSeconds "$age_seconds" \
  --argjson maxAgeSeconds "$max_age_seconds" \
  '{schemaVersion:1,completedAt:$completedAt,completedEpoch:$completedEpoch,ageSeconds:$ageSeconds,maxAgeSeconds:$maxAgeSeconds,fresh:true}'
