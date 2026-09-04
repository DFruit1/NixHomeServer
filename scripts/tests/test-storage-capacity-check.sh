#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq stat

helper="$TESTS_REPO_ROOT/scripts/helpers/storage-capacity-check.sh"
df_mock="$TESTS_REPO_ROOT/scripts/tests/fixtures/storage-capacity-df-mock.sh"
[[ -x "$helper" ]] || {
  echo "Missing executable storage capacity helper: $helper" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status_file="$work/last-storage-capacity.json"
alert_state_file="$work/storage-capacity-alert.timestamp"
monitor_args=()

run_check() {
  local expected_exit="$1"
  local output actual_exit
  shift 1
  set +e
  output="$(
    DF_BIN="$df_mock" \
    STORAGE_CAPACITY_DF_TABLE="$STORAGE_CAPACITY_DF_TABLE" \
      "$helper" \
        --status-file "$status_file" \
        --alert-state-file "$alert_state_file" \
        "${monitor_args[@]}" \
        --warn-percent 80 \
        --critical-percent 90 \
        --cooldown-seconds 86400 \
        "$@"
  )"
  actual_exit=$?
  set -e
  [[ "$actual_exit" == "$expected_exit" ]] || {
    echo "Storage capacity check returned $actual_exit, expected $expected_exit: $output" >&2
    exit 1
  }
  printf '%s\n' "$output"
}

# Both watched filesystems comfortably below thresholds classify as ok.
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500
/mnt/data /dev/mapper/data 2000 200 1800"
monitor_args=(--monitor-path / --monitor-path /mnt/data)
event="$(run_check 0)"
jq -e '
  .schemaVersion == 1
  and .event == "storage_capacity"
  and .state == "ok"
  and .failureClass == "none"
  and .reason == "capacity_ok"
  and .alertRequired == false
  and .alertSuppressed == false
  and .warnPercent == 80
  and .criticalPercent == 90
  and (.paths | length) == 2
  and .paths[0].path == "/"
  and .paths[0].device == "/dev/sda"
  and .paths[0].usedPercent == 50
  and .paths[1].path == "/mnt/data"
  and .paths[1].usedPercent == 10
  and .skippedDuplicateDevices == []
' <<<"$event" >/dev/null
[[ ! -e "$alert_state_file" ]]

# A second monitored path on an already-measured device is deduplicated.
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500
/persist /dev/sda 1000 500 500
/mnt/data /dev/mapper/data 2000 200 1800"
monitor_args=(--monitor-path / --monitor-path /persist --monitor-path /mnt/data)
event="$(run_check 0)"
jq -e '
  (.paths | length) == 2
  and .skippedDuplicateDevices == ["/persist"]
' <<<"$event" >/dev/null

# A warning state is informational and must not arm the alert cooldown.
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500
/mnt/data /dev/mapper/data 2000 1700 300"
monitor_args=(--monitor-path / --monitor-path /mnt/data)
event="$(run_check 0)"
jq -e '
  .state == "warning"
  and .failureClass == "capacity"
  and .reason == "capacity_warning"
  and .operatorActionRequired == false
  and .alertRequired == false
  and .paths[1].usedPercent == 85
' <<<"$event" >/dev/null
[[ ! -e "$alert_state_file" ]]

# Crossing the critical threshold alerts exactly once per cooldown window.
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500
/mnt/data /dev/mapper/data 2000 1820 180"
event="$(run_check 1)"
jq -e '
  .state == "critical"
  and .failureClass == "capacity"
  and .reason == "capacity_critical"
  and .operatorActionRequired == true
  and .alertRequired == true
  and .alertSuppressed == false
' <<<"$event" >/dev/null
[[ "$(stat -c '%a' "$alert_state_file")" == 600 ]]

event="$(run_check 0)"
jq -e '
  .state == "critical"
  and .alertRequired == false
  and .alertSuppressed == true
' <<<"$event" >/dev/null

# Recovery clears the cooldown so the next critical alert fires immediately.
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500
/mnt/data /dev/mapper/data 2000 1700 300"
run_check 0 >/dev/null
[[ ! -e "$alert_state_file" ]]
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500
/mnt/data /dev/mapper/data 2000 1820 180"
run_check 1 >/dev/null

# A missing or unmeasurable filesystem fails closed with an alert.
rm -f "$alert_state_file"
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500"
event="$(run_check 1)"
jq -e '
  .state == "failed"
  and .failureClass == "measurement"
  and .reason == "path_unavailable"
  and .operatorActionRequired == true
  and .alertRequired == true
' <<<"$event" >/dev/null

# The persisted status file mirrors the emitted event.
jq -e --argjson event "$event" '. == $event' "$status_file" >/dev/null
[[ "$(stat -c '%a' "$status_file")" == 600 ]]
if find "$work" -maxdepth 1 -name '.last-storage-capacity.json.*' -print -quit | grep -q .; then
  echo "Storage capacity helper left an atomic-write temporary file behind." >&2
  exit 1
fi

# Invalid threshold ordering is rejected up front.
STORAGE_CAPACITY_DF_TABLE="/ /dev/sda 1000 500 500"
set +e
"$helper" \
  --status-file "$status_file" \
  --alert-state-file "$alert_state_file" \
  --monitor-path / \
  --warn-percent 90 \
  --critical-percent 80 \
  --cooldown-seconds 86400 >/dev/null 2>&1
usage_exit=$?
set -e
[[ "$usage_exit" == 64 ]]

echo "✅ Storage capacity classification and alert cooldown behavior passed."
