#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash date jq mktemp rg

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
marker="$tmpdir/marker.json"
output="$tmpdir/output"
now=2000000000
max_age=3600

write_marker() {
  local schema_version="${2:-1}"
  jq -n \
    --argjson schemaVersion "$schema_version" \
    --arg completedAt "$1" \
    '{schemaVersion:$schemaVersion,completedAt:$completedAt}' >"$marker"
  # Deliberately make filesystem metadata fresh: health must use completedAt.
  touch "$marker"
}

run_check() {
  FRESHNESS_MARKER_NOW_EPOCH="$now" \
    bash scripts/helpers/check-freshness-marker.sh \
      --marker "$marker" \
      --max-age-seconds "$max_age"
}

write_marker "$(date --utc --date="@$((now - 60))" --iso-8601=seconds)"
run_check >"$output"
jq -e '.fresh and .ageSeconds == 60 and .maxAgeSeconds == 3600' "$output" >/dev/null

write_marker "$(date --utc --date="@$((now - max_age - 1))" --iso-8601=seconds)"
if run_check >"$output" 2>&1; then
  echo "Stale completedAt passed because the marker mtime was fresh." >&2
  exit 1
fi
rg -q 'Freshness marker is stale' "$output"

write_marker "not-a-timestamp"
if run_check >"$output" 2>&1; then
  echo "Invalid completedAt timestamp unexpectedly passed freshness validation." >&2
  exit 1
fi
rg -q 'invalid completedAt timestamp' "$output"

write_marker "now"
if run_check >"$output" 2>&1; then
  echo "Relative completedAt timestamp unexpectedly passed freshness validation." >&2
  exit 1
fi
rg -q 'invalid completedAt timestamp' "$output"

write_marker "$(date --utc --date="@$((now - 60))" --iso-8601=seconds)" 2
if run_check >"$output" 2>&1; then
  echo "Unsupported freshness marker schema unexpectedly passed validation." >&2
  exit 1
fi
rg -q 'unsupported schemaVersion: 2' "$output"

write_marker "$(date --utc --date="@$((now + 1))" --iso-8601=seconds)"
if run_check >"$output" 2>&1; then
  echo "Future completedAt timestamp unexpectedly passed freshness validation." >&2
  exit 1
fi
rg -q 'completedAt is in the future' "$output"

echo "✅ JSON completedAt freshness regression tests passed."
