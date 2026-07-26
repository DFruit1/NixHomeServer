#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix rg

gc_helper="scripts/helpers/nix-store-capacity-gc.sh"
require_fixed "$gc_helper" 'nix-collect-garbage --delete-older-than "${NIX_GC_RETENTION_DAYS}d"' \
  "Capacity GC must pass the configured retention period to nix-collect-garbage."
require_fixed modules/Core_Modules/base-system/default.nix 'OnCalendar = "hourly";' \
  "Capacity GC must check hourly so rapid development cannot fill the root filesystem."
require_fixed modules/Core_Modules/base-system/default.nix 'NIX_STORE_MAX_GIB' \
  "Capacity GC must receive the configured Nix store soft cap."
require_fixed modules/Core_Modules/base-system/default.nix 'NIX_GC_RETENTION_DAYS' \
  "Capacity GC must receive the configured generation retention period."
require_fixed documentation/operations.md 'nix_store_gc_completed' \
  "Operations guidance must document the capacity GC completion event."

for vars_file in vars.nix vars.example.nix; do
  require_match "$vars_file" \
    'nixStoreMaxSizeGiB[[:space:]]*=[[:space:]]*[0-9]+;[[:space:]]*#[^\n]+90%' \
    "${vars_file} must explain the Nix store GiB soft cap and its 90% trigger."
  require_match "$vars_file" \
    'nixGcRetentionDays[[:space:]]*=[[:space:]]*45;[[:space:]]*#[^\n]+rollback' \
    "${vars_file} must default to 45-day retention and explain rollback loss."
done

test_dir="$(mktemp -d)"
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

cat >"$mock_bin/du" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
index="$(<"$TEST_DU_INDEX_FILE")"
IFS=, read -r -a values <<<"$TEST_DU_VALUES"
if ((index >= ${#values[@]})); then
  index=$((${#values[@]} - 1))
fi
printf '%s\t%s\n' "${values[$index]}" "${*: -1}"
printf '%s\n' "$((index + 1))" >"$TEST_DU_INDEX_FILE"
EOF

cat >"$mock_bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '1B-blocks Used\n%s %s\n' "$TEST_FS_TOTAL_BYTES" "$TEST_FS_USED_BYTES"
EOF

cat >"$mock_bin/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_FLOCK_BUSY:-0}" == 1 ]]; then
  exit 1
fi
EOF

cat >"$mock_bin/nix-collect-garbage" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_GC_LOG"
if [[ "${TEST_GC_FAIL:-0}" == 1 ]]; then
  printf 'mock collector failed: database is busy\n' >&2
  exit 42
fi
EOF

make_test_executable \
  "$mock_bin/du" \
  "$mock_bin/df" \
  "$mock_bin/flock" \
  "$mock_bin/nix-collect-garbage"

gib=$((1024 * 1024 * 1024))
max_gib=80
trigger_bytes=$((max_gib * gib * 90 / 100))
below_trigger_bytes=$((trigger_bytes - 1))
after_gc_bytes=$((60 * gib))
output_file="$test_dir/output.jsonl"
gc_log="$test_dir/gc.log"
du_index_file="$test_dir/du-index"

run_gc() {
  local du_values="$1"
  local fs_used_bytes="$2"
  local fs_total_bytes="${3:-100000}"
  : >"$output_file"
  : >"$gc_log"
  printf '0\n' >"$du_index_file"
  PATH="$mock_bin:$PATH" \
    NIX_STORE_MAX_GIB="$max_gib" \
    NIX_GC_RETENTION_DAYS=45 \
    NIX_STORE_PATH="$test_dir/store" \
    NIX_GC_LOCK_PATH="$test_dir/maintenance.lock" \
    INVOCATION_ID=0123456789abcdef \
    TEST_DU_VALUES="$du_values" \
    TEST_DU_INDEX_FILE="$du_index_file" \
    TEST_FS_USED_BYTES="$fs_used_bytes" \
    TEST_FS_TOTAL_BYTES="$fs_total_bytes" \
    TEST_GC_LOG="$gc_log" \
    bash "$gc_helper" >"$output_file"
}

mkdir -p "$test_dir/store"

run_gc "$below_trigger_bytes" 50000
if [[ -s "$gc_log" ]]; then
  echo "❌ Capacity GC ran below both configured thresholds." >&2
  exit 1
fi
jq -s -e '
  length == 1
  and .[0].event == "nix_store_gc_check"
  and .[0].decision == "skip"
  and .[0].trigger_reason == "below_threshold"
' "$output_file" >/dev/null || {
  echo "❌ Capacity GC did not report its below-threshold decision." >&2
  cat "$output_file" >&2
  exit 1
}

run_gc "$trigger_bytes,$trigger_bytes,$after_gc_bytes" 50000
if [[ "$(<"$gc_log")" != '--delete-older-than 45d' ]]; then
  echo "❌ Capacity GC did not invoke the expected 45-day collection." >&2
  cat "$gc_log" >&2
  exit 1
fi
jq -s -e --argjson before "$trigger_bytes" --argjson after "$after_gc_bytes" '
  map(.event) == ["nix_store_gc_check", "nix_store_gc_recheck", "nix_store_gc_started", "nix_store_gc_completed"]
  and .[0].decision == "collect"
  and .[0].trigger_reason == "store_size"
  and .[0].store_bytes == $before
  and .[3].store_bytes_before == $before
  and .[3].store_bytes_after == $after
  and .[3].freed_bytes == ($before - $after)
  and .[3].retention_days == 45
' "$output_file" >/dev/null || {
  echo "❌ Capacity GC store-size telemetry is incomplete or incorrect." >&2
  cat "$output_file" >&2
  exit 1
}

run_gc "$((10 * gib)),$((9 * gib)),$((9 * gib))" 90000
jq -s -e '
  .[0].decision == "collect"
  and .[0].trigger_reason == "filesystem_capacity"
  and .[0].filesystem_used_percent == 90
' "$output_file" >/dev/null || {
  echo "❌ Capacity GC did not react to Nix store filesystem pressure." >&2
  cat "$output_file" >&2
  exit 1
}

# GNU df rounds displayed percentages upward. An actual 89.1% must remain below
# this service's exact 90% trigger.
run_gc "$below_trigger_bytes" 89100 100000
jq -e '
  .event == "nix_store_gc_check"
  and .decision == "skip"
  and .filesystem_used_bytes == 89100
  and .filesystem_total_bytes == 100000
' "$output_file" >/dev/null || {
  echo "❌ Capacity GC used df's rounded display percentage instead of exact bytes." >&2
  cat "$output_file" >&2
  exit 1
}

for invalid_max_gib in 0 -1 01 nope 1048577; do
  : >"$gc_log"
  printf '0\n' >"$du_index_file"
  if PATH="$mock_bin:$PATH" \
      NIX_STORE_MAX_GIB="$invalid_max_gib" \
      NIX_GC_RETENTION_DAYS=45 \
      NIX_STORE_PATH="$test_dir/store" \
      NIX_GC_LOCK_PATH="$test_dir/maintenance.lock" \
      TEST_DU_VALUES="$trigger_bytes" \
      TEST_DU_INDEX_FILE="$du_index_file" \
      TEST_FS_USED_BYTES=50000 \
      TEST_FS_TOTAL_BYTES=100000 \
      TEST_GC_LOG="$gc_log" \
      bash "$gc_helper" >"$output_file" 2>&1; then
    echo "❌ Capacity GC accepted invalid GiB limit: ${invalid_max_gib}." >&2
    exit 1
  fi
  if [[ -s "$gc_log" ]]; then
    echo "❌ Capacity GC ran after rejecting invalid configuration." >&2
    exit 1
  fi
done

for invalid_days in 0 -1 045 nope 36501; do
  : >"$gc_log"
  printf '0\n' >"$du_index_file"
  if PATH="$mock_bin:$PATH" \
      NIX_STORE_MAX_GIB="$max_gib" \
      NIX_GC_RETENTION_DAYS="$invalid_days" \
      NIX_STORE_PATH="$test_dir/store" \
      NIX_GC_LOCK_PATH="$test_dir/maintenance.lock" \
      TEST_DU_VALUES="$trigger_bytes" \
      TEST_DU_INDEX_FILE="$du_index_file" \
      TEST_FS_USED_BYTES=50000 \
      TEST_FS_TOTAL_BYTES=100000 \
      TEST_GC_LOG="$gc_log" \
      bash "$gc_helper" >"$output_file" 2>&1; then
    echo "❌ Capacity GC accepted invalid retention days: ${invalid_days}." >&2
    exit 1
  fi
done

: >"$gc_log"
printf '0\n' >"$du_index_file"
lock_status=0
PATH="$mock_bin:$PATH" \
  NIX_STORE_MAX_GIB="$max_gib" \
  NIX_GC_RETENTION_DAYS=45 \
  NIX_STORE_PATH="$test_dir/store" \
  NIX_GC_LOCK_PATH="$test_dir/maintenance.lock" \
  TEST_DU_VALUES="$trigger_bytes" \
  TEST_DU_INDEX_FILE="$du_index_file" \
  TEST_FS_USED_BYTES=50000 \
  TEST_FS_TOTAL_BYTES=100000 \
  TEST_GC_LOG="$gc_log" \
  TEST_FLOCK_BUSY=1 \
  bash "$gc_helper" >"$output_file" 2>&1 || lock_status=$?
if ((lock_status != 75)) || [[ -s "$gc_log" ]]; then
  echo "❌ Capacity GC did not defer safely when another maintenance job held the lock." >&2
  cat "$output_file" >&2
  exit 1
fi
jq -s -e '
  map(.event) == ["nix_store_gc_check", "nix_store_gc_deferred"]
  and .[0].decision == "collect"
' "$output_file" >/dev/null || {
  echo "❌ Capacity GC did not measure and report pressure before lock deferral." >&2
  cat "$output_file" >&2
  exit 1
}

: >"$gc_log"
printf '0\n' >"$du_index_file"
gc_failure_status=0
PATH="$mock_bin:$PATH" \
  NIX_STORE_MAX_GIB="$max_gib" \
  NIX_GC_RETENTION_DAYS=45 \
  NIX_STORE_PATH="$test_dir/store" \
  NIX_GC_LOCK_PATH="$test_dir/maintenance.lock" \
  NIX_GC_FAILURE_MARKER="$test_dir/failure-reported" \
  TEST_DU_VALUES="$trigger_bytes,$trigger_bytes" \
  TEST_DU_INDEX_FILE="$du_index_file" \
  TEST_FS_USED_BYTES=50000 \
  TEST_FS_TOTAL_BYTES=100000 \
  TEST_GC_LOG="$gc_log" \
  TEST_GC_FAIL=1 \
  bash "$gc_helper" >"$output_file" 2>&1 || gc_failure_status=$?
if ((gc_failure_status != 42)) || [[ ! -e "$test_dir/failure-reported" ]]; then
  echo "❌ Capacity GC did not preserve collector failure status and marker." >&2
  cat "$output_file" >&2
  exit 1
fi
jq -s -e '
  .[-1].event == "nix_store_gc_failed"
  and .[-1].stage == "garbage_collection"
  and .[-1].exit_status == 42
  and ((.[-1].collector_output_base64 | @base64d) | contains("database is busy"))
' "$output_file" >/dev/null || {
  echo "❌ Capacity GC failure telemetry omitted the collector diagnostic." >&2
  cat "$output_file" >&2
  exit 1
}

host="$(test_default_host)"
service_json="$(
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      cfg = (builtins.getAttr host flake.nixosConfigurations).config;
      service = cfg.systemd.services.nixhomeserver-nix-gc;
      timer = cfg.systemd.timers.nixhomeserver-nix-gc;
    in {
      inherit (service) environment;
      execStart = toString service.serviceConfig.ExecStart;
      successExitStatus = service.serviceConfig.SuccessExitStatus;
      execStopPost = toString service.serviceConfig.ExecStopPost;
      restart = service.serviceConfig.Restart or null;
      onFailure = service.unitConfig.OnFailure;
      onFailureJobMode = service.unitConfig.OnFailureJobMode;
      onCalendar = timer.timerConfig.OnCalendar;
      persistent = timer.timerConfig.Persistent;
      randomizedDelay = timer.timerConfig.RandomizedDelaySec;
      optimiseSuccessExitStatus =
        cfg.systemd.services.nixhomeserver-nix-optimise.serviceConfig.SuccessExitStatus;
      maxSizeGiB = (builtins.getAttr host flake.lib.nixhomeserverSettings).nixStoreMaxSizeGiB;
      retentionDays = (builtins.getAttr host flake.lib.nixhomeserverSettings).nixGcRetentionDays;
    }
  '
)"

jq -e '
  .environment.NIX_STORE_MAX_GIB == "80"
  and .environment.NIX_GC_RETENTION_DAYS == "45"
  and (.execStart | contains("nixhomeserver-nix-store-capacity-gc"))
  and (.successExitStatus | index(75) != null)
  and (.execStopPost | contains("nix_store_gc_failed"))
  and .restart == null
  and .onFailure == ["nixhomeserver-failure-alert@%n.service"]
  and .onFailureJobMode == "replace-irreversibly"
  and .onCalendar == "hourly"
  and .persistent == true
  and .randomizedDelay == "10m"
  and (.optimiseSuccessExitStatus | index(75) != null)
  and .maxSizeGiB == 80
  and .retentionDays == 45
' <<<"$service_json" >/dev/null || {
  echo "❌ Evaluated capacity GC service does not match the configured policy." >&2
  jq . <<<"$service_json" >&2
  exit 1
}

invalid_log="$test_dir/invalid-settings.log"
for invalid_field in nixStoreMaxSizeGiB nixGcRetentionDays; do
  if NIXHOMESERVER_INVALID_GC_FIELD="$invalid_field" nix eval --impure --raw --expr '
      let
        flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
        lib = flake.inputs.nixpkgs.lib;
        base = import ./vars.nix { inherit lib; };
        field = builtins.getEnv "NIXHOMESERVER_INVALID_GC_FIELD";
        invalid = base // { ${field} = 0; };
      in
      (import ./lib/validate-host-settings.nix {
        inherit lib;
        hostName = base.hostname;
        settings = invalid;
      }).hostname
    ' >"$invalid_log" 2>&1; then
    echo "❌ Host validation accepted ${invalid_field} = 0." >&2
    exit 1
  fi
  if ! rg -Fq "system.${invalid_field} must be an integer" "$invalid_log"; then
    echo "❌ Invalid ${invalid_field} failed without actionable guidance." >&2
    cat "$invalid_log" >&2
    exit 1
  fi
done

echo "✅ Nix store capacity-triggered garbage collection tests passed."
