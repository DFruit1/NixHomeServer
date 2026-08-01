#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq stat

helper="$TESTS_REPO_ROOT/scripts/helpers/rclone-mega-status-event.sh"
[[ -x "$helper" ]] || {
  echo "Missing executable MEGA status-event helper: $helper" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status_file="$work/last-mega-sync-status.json"

event="$($helper \
  --status-file "$status_file" \
  --attempt-id 'sync-1722470400-1234' \
  --state blocked \
  --failure-class capacity \
  --reason local_repository_limit \
  --message 'Local repository reached its safety ceiling.' \
  --retryable false \
  --operator-action-required true \
  --repository-bytes 21431375982 \
  --limit-bytes 20401094656)"

jq -e '
  .schemaVersion == 1
  and .event == "mega_kopia_sync_state"
  and .attemptId == "sync-1722470400-1234"
  and .state == "blocked"
  and .failureClass == "capacity"
  and .reason == "local_repository_limit"
  and .message == "Local repository reached its safety ceiling."
  and .retryable == false
  and .operatorActionRequired == true
  and .repositoryBytes == 21431375982
  and .limitBytes == 20401094656
  and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T"))
' <<<"$event" >/dev/null

jq -e --argjson event "$event" '. == $event' "$status_file" >/dev/null
[[ "$(stat -c '%a' "$status_file")" == 600 ]] || {
  echo "MEGA status event is not owner-readable only." >&2
  exit 1
}
if find "$work" -maxdepth 1 -name '.last-mega-sync-status.json.*' -print -quit | grep -q .; then
  echo "MEGA status event left an atomic-write temporary file behind." >&2
  exit 1
fi

expect_rejected() {
  local description="$1"
  shift
  if "$helper" \
    --status-file "$work/rejected.json" \
    --attempt-id 'sync-1722470400-1234' \
    --state failed \
    --failure-class remote \
    --reason remote_command_failed \
    --message 'Safe diagnostic.' \
    --retryable false \
    --operator-action-required true \
    --repository-bytes 1 \
    --limit-bytes 2 \
    "$@" >/dev/null 2>&1; then
    echo "MEGA status helper accepted invalid $description." >&2
    exit 1
  fi
}

expect_rejected state --state unknown
expect_rejected failure-class --failure-class arbitrary
expect_rejected reason --reason 'contains spaces'
expect_rejected boolean --retryable perhaps
expect_rejected byte-count --repository-bytes -1
expect_rejected multiline-message --message $'line one\nline two'

echo "✅ Structured MEGA sync status-event behavior passed."
