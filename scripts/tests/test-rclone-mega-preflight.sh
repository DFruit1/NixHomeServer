#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq sha256sum

helper="$TESTS_REPO_ROOT/scripts/helpers/rclone-mega-preflight.sh"
mock_rclone="$TESTS_REPO_ROOT/scripts/tests/fixtures/rclone-mega-preflight-mock.sh"
[[ -x "$helper" ]] || {
  echo "Missing executable MEGA preflight helper: $helper" >&2
  exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expected_identity='managed-kopia-repository-identity'
expected_fingerprint="$(printf '%s' "$expected_identity" | sha256sum | cut -d ' ' -f 1)"

reset_fixture() {
  rm -rf "$work/fixture"
  mkdir -p "$work/fixture" "$work/state"
  rm -f "$work/state/preflight-result.json"
  printf '%s' "$expected_identity" > "$work/fixture/kopia.repository.f"
  printf '{"total":100,"used":50,"free":50}\n' > "$work/fixture/quota.json"
  printf '{"count":3,"bytes":40}\n' > "$work/fixture/size.json"
  printf '{"count":1,"bytes":10}\n' > "$work/fixture/transfer-size.json"
  printf '{"count":4,"bytes":2}\n' > "$work/fixture/control-size.json"
  printf '{"count":0,"bytes":0}\n' > "$work/fixture/delete-size.json"
  : > "$work/fixture/missing-on-destination.txt"
  : > "$work/fixture/different.txt"
  : > "$work/fixture/missing-on-source.txt"
  : > "$work/fixture/errors.txt"
  printf '.nixhomeserver-rclone-owner.json\nkopia.repository.f\np0000000000000000-s0000000000000000.f\n' > "$work/fixture/listing.txt"
  printf '.shards\nkopia.blobcfg.f\nkopia.maintenance.f\nkopia.repository.f\n' > "$work/always-transfer.txt"
  jq -n \
    --arg repositoryFingerprint "$expected_fingerprint" \
    --arg destination 'mega:NixHomeServer/kopia' \
    '{schemaVersion:1,repositoryFingerprint:$repositoryFingerprint,destination:$destination}' \
    > "$work/fixture/marker.json"
}

run_preflight() {
  RCLONE_MOCK_FIXTURE="$work/fixture" \
  RCLONE_BIN="$mock_rclone" \
  JQ_BIN="$(command -v jq)" \
  SHA256SUM_BIN="$(command -v sha256sum)" \
  CUT_BIN="$(command -v cut)" \
  MKTEMP_BIN="$(command -v mktemp)" \
  RM_BIN="$(command -v rm)" \
    "$helper" \
      --config "$work/rclone.conf" \
      --source "$work/local-kopia" \
      --cache-dir "$work/cache" \
      --checkers 8 \
      --always-transfer-from "$work/always-transfer.txt" \
      --remote-root 'mega:' \
      --destination 'mega:NixHomeServer/kopia' \
      --marker-name '.nixhomeserver-rclone-owner.json' \
      --expected-fingerprint "$expected_fingerprint" \
      --repository-bytes "${1:-60}" \
      --limit-bytes 90 \
      --control-reserve-bytes 1 \
      --result-file "$work/state/preflight-result.json" \
      --state-dir "$work/state"
}

expect_failure() {
  local expected_code="$1"
  local expected_class="$2"
  local expected_reason="$3"
  local expected_message="$4"
  shift 4
  local log="$work/failure.log"
  set +e
  "$@" >"$log" 2>&1
  local actual_code=$?
  set -e
  if (( actual_code == 0 )); then
    echo "Expected MEGA preflight to fail: $expected_message" >&2
    exit 1
  fi
  [[ "$actual_code" == "$expected_code" ]] || {
    echo "MEGA preflight used exit $actual_code instead of $expected_code for: $expected_message" >&2
    cat "$log" >&2
    exit 1
  }
  rg -F "$expected_message" "$log" >/dev/null || {
    echo "MEGA preflight failed without the expected reason: $expected_message" >&2
    cat "$log" >&2
    exit 1
  }
  jq -e \
    --arg failureClass "$expected_class" \
    --arg reason "$expected_reason" \
    '.schemaVersion == 1 and .failureClass == $failureClass and .reason == $reason and (.message | length > 0)' \
    "$work/state/preflight-result.json" >/dev/null || {
    echo "MEGA preflight did not persist the expected failure classification." >&2
    cat "$work/state/preflight-result.json" >&2
    exit 1
  }
}

reset_fixture
run_preflight
[[ ! -e "$work/fixture/copied-marker.json" ]] || {
  echo "An already-owned destination unexpectedly rewrote its marker." >&2
  exit 1
}

reset_fixture
printf '%s' 'different-kopia-repository' > "$work/fixture/kopia.repository.f"
expect_failure 77 safety remote_identity_mismatch 'different Kopia repository identity' run_preflight

reset_fixture
printf '5\n' > "$work/fixture/identity-error"
expect_failure 75 transient remote_identity_read_temporary 'identity exists but cannot be read' run_preflight

reset_fixture
printf '7\n' > "$work/fixture/identity-error"
expect_failure 77 safety remote_identity_unreadable 'identity exists but cannot be read' run_preflight

reset_fixture
printf 'kopia.repository.f\np0000000000000000-s0000000000000000.f\n' > "$work/fixture/listing.txt"
printf '5\n' > "$work/fixture/identity-error"
expect_failure 75 transient remote_identity_read_temporary 'no readable Kopia repository identity' run_preflight

reset_fixture
: > "$work/fixture/marker-error"
expect_failure 77 safety ownership_marker_unreadable 'ownership marker exists but cannot be read' run_preflight

reset_fixture
printf '{}\n' > "$work/fixture/marker.json"
expect_failure 77 safety ownership_marker_invalid 'ownership marker is malformed' run_preflight

reset_fixture
printf '.nixhomeserver-rclone-owner.json\np0000000000000000-s0000000000000000.f\n' > "$work/fixture/listing.txt"
printf '7\n' > "$work/fixture/identity-error"
run_preflight

reset_fixture
printf '7\n' > "$work/fixture/plan-error"
expect_failure 78 remote transfer_plan_failed 'read-only MEGA transfer plan failed' run_preflight

reset_fixture
printf '5\n' > "$work/fixture/list-error"
expect_failure 75 transient destination_list_temporary 'destination cannot be listed' run_preflight

reset_fixture
printf 'unreadable-pack.f\n' > "$work/fixture/errors.txt"
expect_failure 78 remote transfer_plan_comparison_errors 'transfer plan found comparison errors' run_preflight

reset_fixture
: > "$work/fixture/listing.txt"
printf '{"total":100,"used":10,"free":90}\n' > "$work/fixture/quota.json"
printf '{"count":0,"bytes":0}\n' > "$work/fixture/size.json"
run_preflight
jq -e \
  --arg repositoryFingerprint "$expected_fingerprint" \
  --arg destination 'mega:NixHomeServer/kopia' \
  '.schemaVersion == 1 and .repositoryFingerprint == $repositoryFingerprint and .destination == $destination' \
  "$work/fixture/copied-marker.json" >/dev/null

reset_fixture
printf 'kopia.repository.f\np0000000000000000-s0000000000000000.f\n' > "$work/fixture/listing.txt"
run_preflight
[[ -s "$work/fixture/copied-marker.json" ]] || {
  echo "A matching markerless repository was not safely adopted." >&2
  exit 1
}

reset_fixture
printf '.nixhomeserver-rclone-owner.json\n.nixhomeserver-rclone-owner.json\nkopia.repository.f\n' > "$work/fixture/listing.txt"
expect_failure 77 safety duplicate_identity_objects 'duplicate ownership or identity objects' run_preflight

reset_fixture
printf '{"total":100,"used":80,"free":20}\n' > "$work/fixture/quota.json"
printf '{"count":3,"bytes":20}\n' > "$work/fixture/size.json"
expect_failure 76 capacity projected_usage_limit 'projected MEGA usage' run_preflight 50

reset_fixture
printf '{"total":100,"used":80,"free":20}\n' > "$work/fixture/quota.json"
printf '{"count":3,"bytes":80}\n' > "$work/fixture/size.json"
printf '{"count":2,"bytes":30}\n' > "$work/fixture/transfer-size.json"
expect_failure 76 capacity insufficient_upload_space 'planned uploads require' run_preflight 80

reset_fixture
printf '{"total":100,"used":80,"free":20}\n' > "$work/fixture/quota.json"
printf '{"count":3,"bytes":80}\n' > "$work/fixture/size.json"
printf '{"count":2,"bytes":18}\n' > "$work/fixture/transfer-size.json"
printf '{"count":1,"bytes":20}\n' > "$work/fixture/delete-size.json"
run_preflight 70

reset_fixture
printf '{"total":100,"used":80,"free":20}\n' > "$work/fixture/quota.json"
printf '{"count":3,"bytes":80}\n' > "$work/fixture/size.json"
printf '{"count":2,"bytes":15}\n' > "$work/fixture/transfer-size.json"
expect_failure 76 capacity transient_usage_limit 'transient MEGA usage' run_preflight 70

reset_fixture
printf 'kopia.repository.f\np0000000000000000-s0000000000000000.f\n' > "$work/fixture/listing.txt"
printf '{"total":100,"used":89,"free":11}\n' > "$work/fixture/quota.json"
printf '{"count":3,"bytes":80}\n' > "$work/fixture/size.json"
printf '{"count":0,"bytes":0}\n' > "$work/fixture/transfer-size.json"
printf '{"count":1,"bytes":20}\n' > "$work/fixture/delete-size.json"
expect_failure 76 capacity marker_upload_limit 'ownership marker would reach' run_preflight 50

reset_fixture
expect_failure 76 capacity local_repository_limit 'local repository reached the configured safety ceiling' run_preflight 90

# A failed result rename must not accumulate a persistent temporary file.
reset_fixture
set +e
RCLONE_MOCK_FIXTURE="$work/fixture" \
RCLONE_BIN="$mock_rclone" \
JQ_BIN="$(command -v jq)" \
SHA256SUM_BIN="$(command -v sha256sum)" \
CUT_BIN="$(command -v cut)" \
MKTEMP_BIN="$(command -v mktemp)" \
MV_BIN="$(command -v false)" \
CHMOD_BIN="$(command -v chmod)" \
RM_BIN="$(command -v rm)" \
  "$helper" \
    --config "$work/rclone.conf" \
    --source "$work/local-kopia" \
    --cache-dir "$work/cache" \
    --checkers 8 \
    --always-transfer-from "$work/always-transfer.txt" \
    --remote-root 'mega:' \
    --destination 'mega:NixHomeServer/kopia' \
    --marker-name '.nixhomeserver-rclone-owner.json' \
    --expected-fingerprint "$expected_fingerprint" \
    --repository-bytes 60 \
    --limit-bytes 90 \
    --control-reserve-bytes 1 \
    --result-file "$work/state/preflight-result.json" \
    --state-dir "$work/state" >/dev/null 2>&1
rename_exit=$?
set -e
(( rename_exit != 0 ))
if find "$work/state" -maxdepth 1 -name '.mega-preflight-result.*' -print -quit | grep -q .; then
  echo "MEGA preflight left a failed result-write temporary file behind." >&2
  exit 1
fi

echo "✅ MEGA live-quota and remote-identity preflight behavior passed."
