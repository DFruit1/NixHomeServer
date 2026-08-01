#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq stat

helper="$TESTS_REPO_ROOT/scripts/helpers/rclone-mega-capacity-check.sh"
rclone_mock="$TESTS_REPO_ROOT/scripts/tests/fixtures/rclone-mega-capacity-mock.sh"
du_mock="$TESTS_REPO_ROOT/scripts/tests/fixtures/rclone-mega-capacity-du-mock.sh"
[[ -x "$helper" ]] || {
  echo "Missing executable MEGA capacity helper: $helper" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status_file="$work/last-mega-capacity.json"
alert_state_file="$work/mega-capacity-alert.timestamp"
sync_status_file="$work/last-mega-sync-status.json"
quota_file="$work/quota.json"
source_dir="$work/repository"
mkdir "$source_dir"

run_check() {
  local repository_bytes="$1"
  local expected_exit="$2"
  local output actual_exit
  shift 2
  set +e
  output="$(
    RCLONE_BIN="$rclone_mock" \
    DU_BIN="$du_mock" \
    RCLONE_CAPACITY_QUOTA_FILE="$quota_file" \
    RCLONE_CAPACITY_REPOSITORY_BYTES="$repository_bytes" \
      "$helper" \
        --config "$work/rclone.conf" \
        --remote 'mega:' \
        --source "$source_dir" \
        --status-file "$status_file" \
        --alert-state-file "$alert_state_file" \
        --sync-status-file "$sync_status_file" \
        --warn-percent 80 \
        --critical-percent 90 \
        --limit-bytes 1000 \
        --cooldown-seconds 86400 \
        "$@"
  )"
  actual_exit=$?
  set -e
  [[ "$actual_exit" == "$expected_exit" ]] || {
    echo "Capacity check returned $actual_exit, expected $expected_exit: $output" >&2
    exit 1
  }
  printf '%s\n' "$output"
}

printf '{"total":2000,"used":200,"free":1800}\n' > "$quota_file"
event="$(run_check 500 0)"
jq -e '
  .schemaVersion == 1
  and .event == "mega_backup_capacity"
  and .state == "ok"
  and .failureClass == "none"
  and .reason == "capacity_ok"
  and .alertRequired == false
  and .alertSuppressed == false
  and .repositoryBytes == 500
  and .repositoryPercent == 50
  and .remoteUsedPercent == 10
' <<<"$event" >/dev/null
[[ ! -e "$alert_state_file" ]]

# A backwards clock step remains inside the existing cooldown window.
printf '{"total":2000,"used":1820,"free":180}\n' > "$quota_file"
future_alert=$(( $(date +%s) + 3600 ))
printf '%s\n' "$future_alert" > "$alert_state_file"
event="$(run_check 500 0)"
jq -e '.state == "critical" and .alertSuppressed == true and .alertRequired == false' \
  <<<"$event" >/dev/null

# Once a full cooldown has elapsed, the actionable alert is emitted again.
expired_alert=$(( $(date +%s) - 86401 ))
printf '%s\n' "$expired_alert" > "$alert_state_file"
event="$(run_check 500 1)"
jq -e '.state == "critical" and .alertSuppressed == false and .alertRequired == true' \
  <<<"$event" >/dev/null
rm -f "$alert_state_file"
printf '{"total":2000,"used":200,"free":1800}\n' > "$quota_file"

# A transfer-plan block must alert even when current raw usage is below 90%.
jq -nc '
  {
    schemaVersion: 1,
    event: "mega_kopia_sync_state",
    state: "blocked",
    failureClass: "capacity",
    reason: "projected_usage_limit"
  }
' > "$sync_status_file"
event="$(run_check 500 1)"
jq -e '
  .state == "blocked"
  and .failureClass == "capacity"
  and .reason == "offsite_sync_capacity_blocked"
  and .operatorActionRequired == true
  and .alertRequired == true
' <<<"$event" >/dev/null
rm -f "$sync_status_file" "$alert_state_file"

# Well-formed JSON with an unknown state must fail closed, not clear alerts.
jq -nc '
  {
    schemaVersion: 1,
    event: "mega_kopia_sync_state",
    state: "unknown",
    failureClass: "capacity",
    reason: "projected_usage_limit"
  }
' > "$sync_status_file"
event="$(run_check 500 1)"
jq -e '
  .state == "failed"
  and .failureClass == "repository"
  and .reason == "sync_status_invalid"
  and .alertRequired == true
' <<<"$event" >/dev/null
rm -f "$sync_status_file" "$alert_state_file"

printf '{"total":2000,"used":1700,"free":300}\n' > "$quota_file"
event="$(run_check 500 0)"
jq -e '
  .state == "warning"
  and .failureClass == "capacity"
  and .reason == "capacity_warning"
  and .operatorActionRequired == false
  and .alertRequired == false
' <<<"$event" >/dev/null

printf '{"total":2000,"used":1820,"free":180}\n' > "$quota_file"
event="$(run_check 500 1)"
jq -e '
  .state == "critical"
  and .failureClass == "capacity"
  and .reason == "capacity_critical"
  and .operatorActionRequired == true
  and .alertRequired == true
  and .alertSuppressed == false
' <<<"$event" >/dev/null
[[ "$(stat -c '%a' "$alert_state_file")" == 600 ]]

event="$(run_check 500 0)"
jq -e '
  .state == "critical"
  and .alertRequired == false
  and .alertSuppressed == true
' <<<"$event" >/dev/null

# Recovery rearms the alert even if the previous alert was recent.
printf '{"total":2000,"used":1700,"free":300}\n' > "$quota_file"
run_check 500 0 >/dev/null
[[ ! -e "$alert_state_file" ]]
printf '{"total":2000,"used":1820,"free":180}\n' > "$quota_file"
run_check 500 1 >/dev/null

# The hard local repository ceiling is distinct from an early warning.
rm -f "$alert_state_file"
printf '{"total":2000,"used":200,"free":1800}\n' > "$quota_file"
event="$(run_check 1000 1)"
jq -e '
  .state == "blocked"
  and .failureClass == "capacity"
  and .reason == "local_repository_limit"
  and .repositoryPercent == 100
  and .alertRequired == true
' <<<"$event" >/dev/null

# A quota lookup failure is operationally different from a capacity block.
rm -f "$alert_state_file"
set +e
event="$(
  RCLONE_BIN="$rclone_mock" \
  DU_BIN="$du_mock" \
  RCLONE_CAPACITY_ERROR_EXIT=5 \
  RCLONE_CAPACITY_QUOTA_FILE="$quota_file" \
  RCLONE_CAPACITY_REPOSITORY_BYTES=500 \
    "$helper" \
      --config "$work/rclone.conf" \
      --remote 'mega:' \
      --source "$source_dir" \
      --status-file "$status_file" \
      --alert-state-file "$alert_state_file" \
      --sync-status-file "$sync_status_file" \
      --warn-percent 80 \
      --critical-percent 90 \
      --limit-bytes 1000 \
      --cooldown-seconds 86400
)"
actual_exit=$?
set -e
[[ "$actual_exit" == 1 ]]
jq -e '
  .state == "failed"
  and .failureClass == "remote"
  and .reason == "remote_quota_unavailable"
  and .operatorActionRequired == true
  and .alertRequired == true
' <<<"$event" >/dev/null

jq -e --argjson event "$event" '. == $event' "$status_file" >/dev/null
[[ "$(stat -c '%a' "$status_file")" == 600 ]]
if find "$work" -maxdepth 1 -name '.last-mega-capacity.json.*' -print -quit | grep -q .; then
  echo "MEGA capacity helper left an atomic-write temporary file behind." >&2
  exit 1
fi

# A failed status rename must remove its temporary file.
rm -f "$sync_status_file" "$alert_state_file"
printf '{"total":2000,"used":200,"free":1800}\n' > "$quota_file"
set +e
RCLONE_BIN="$rclone_mock" \
DU_BIN="$du_mock" \
MV_BIN="$(command -v false)" \
RCLONE_CAPACITY_QUOTA_FILE="$quota_file" \
RCLONE_CAPACITY_REPOSITORY_BYTES=500 \
  "$helper" \
    --config "$work/rclone.conf" \
    --remote 'mega:' \
    --source "$source_dir" \
    --status-file "$status_file" \
    --alert-state-file "$alert_state_file" \
    --sync-status-file "$sync_status_file" \
    --warn-percent 80 \
    --critical-percent 90 \
    --limit-bytes 1000 \
    --cooldown-seconds 86400 >/dev/null 2>&1
rename_exit=$?
set -e
(( rename_exit != 0 ))
if find "$work" -maxdepth 1 -name '.last-mega-capacity.json.*' -print -quit | grep -q .; then
  echo "MEGA capacity helper left a failed status-write temporary file behind." >&2
  exit 1
fi

echo "✅ MEGA capacity classification and alert cooldown behavior passed."
