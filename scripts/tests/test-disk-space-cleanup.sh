#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq nix rg

cleanup_helper="scripts/helpers/disk-space-cleanup.sh"
require_fixed "$cleanup_helper" 'journalctl --vacuum-time="$journal_vacuum_time"' \
  "Disk cleanup must vacuum the journal to the configured retention window."
require_fixed "$cleanup_helper" 'systemd-tmpfiles --clean' \
  "Disk cleanup must run age-based tmpfiles cleanup."
require_fixed "$cleanup_helper" 'nix-collect-garbage --delete-older-than "${nix_gc_retention_days}d"' \
  "Disk cleanup must pass the configured retention period to nix-collect-garbage."
require_fixed modules/Core_Modules/disk-cleanup/default.nix 'OnCalendar = "*:0/30:00";' \
  "Disk cleanup must check every 30 minutes so rising usage is caught promptly."
require_fixed modules/Core_Modules/disk-cleanup/default.nix 'DISK_CLEANUP_TRIGGER_PERCENT' \
  "Disk cleanup must receive the configured trigger percent."
require_fixed modules/Core_Modules/disk-cleanup/default.nix 'DISK_CLEANUP_JOURNAL_VACUUM_TIME' \
  "Disk cleanup must receive the configured journal vacuum window."
require_fixed documentation/operations.md 'disk_cleanup_completed' \
  "Operations guidance must document the disk cleanup completion event."

for vars_file in vars.nix vars.example.nix; do
  require_match "$vars_file" \
    'triggerPercent[[:space:]]*=[[:space:]]*85;[[:space:]]*#[^\n]+85%' \
    "${vars_file} must default the disk cleanup trigger to 85%."
  require_match "$vars_file" \
    'journalVacuumTime[[:space:]]*=[[:space:]]*"7d";' \
    "${vars_file} must default journal retention under pressure to 7 days."
done
for vars_file in vars.nix vars.example.nix; do
  require_match "$vars_file" \
    'localDiskCleanup[[:space:]]*=[[:space:]]*\{' \
    "${vars_file} must define the workstation local disk cleanup settings."
  require_match "$vars_file" \
    'monitorPaths[[:space:]]*=[[:space:]]*\[ "/nix" \];' \
    "${vars_file} must default the workstation cleanup to the main SSD holding the Nix store."
done
require_fixed scripts/deploy.sh 'DISK_CLEANUP_TRIGGER_PERCENT="$local_disk_cleanup_trigger_percent"' \
  "Deploy must pass the configured workstation trigger percent to the cleanup helper."
require_fixed scripts/deploy.sh 'DISK_CLEANUP_MONITOR_PATHS="$local_disk_cleanup_monitor_paths"' \
  "Deploy must pass the configured workstation main SSD to the cleanup helper."

test_dir="$(mktemp -d)"
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin" "$test_dir/root" "$test_dir/store"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

cat >"$mock_bin/df" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
index="$(<"$TEST_DF_INDEX_FILE")"
IFS=, read -r -a totals <<<"$TEST_DF_TOTALS"
IFS=, read -r -a useds <<<"$TEST_DF_USEDS"
if ((index >= ${#totals[@]})); then
  index=$((${#totals[@]} - 1))
fi
printf 'Size Used\n%s %s\n' "${totals[$index]}" "${useds[$index]}"
printf '%s\n' "$((index + 1))" >"$TEST_DF_INDEX_FILE"
EOF

cat >"$mock_bin/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
path="${@: -1}"
case "$path" in
  */store)
    printf '%s\n' "${TEST_STORE_DEV:-1}"
    ;;
  *)
    printf '%s\n' "${TEST_MONITOR_DEV:-1}"
    ;;
esac
EOF

cat >"$mock_bin/flock" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${TEST_FLOCK_BUSY:-0}" == 1 ]]; then
  exit 1
fi
EOF

cat >"$mock_bin/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_JOURNALCTL_LOG"
if [[ "${TEST_JOURNALCTL_FAIL:-0}" == 1 ]]; then
  printf 'mock vacuum failed: cannot archive journal\n' >&2
  exit 42
fi
EOF

cat >"$mock_bin/systemd-tmpfiles" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_TMPFILES_LOG"
EOF

cat >"$mock_bin/nix-collect-garbage" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_GC_LOG"
EOF

make_test_executable \
  "$mock_bin/df" \
  "$mock_bin/stat" \
  "$mock_bin/flock" \
  "$mock_bin/journalctl" \
  "$mock_bin/systemd-tmpfiles" \
  "$mock_bin/nix-collect-garbage"

output_file="$test_dir/output.jsonl"
journalctl_log="$test_dir/journalctl.log"
tmpfiles_log="$test_dir/tmpfiles.log"
gc_log="$test_dir/gc.log"
df_index_file="$test_dir/df-index"

run_cleanup() {
  local fs_used_bytes="$1"
  local fs_total_bytes="${2:-100000}"
  : >"$output_file"
  : >"$journalctl_log"
  : >"$tmpfiles_log"
  : >"$gc_log"
  printf '0\n' >"$df_index_file"
  PATH="$mock_bin:$PATH" \
    DISK_CLEANUP_TRIGGER_PERCENT=85 \
    DISK_CLEANUP_MONITOR_PATHS="$test_dir/root" \
    DISK_CLEANUP_JOURNAL_VACUUM_TIME=7d \
    DISK_CLEANUP_NIX_GC_RETENTION_DAYS=45 \
    DISK_CLEANUP_LOCK_PATH="$test_dir/maintenance.lock" \
    DISK_CLEANUP_STORE_PATH="$test_dir/store" \
    INVOCATION_ID=0123456789abcdef \
    TEST_DF_TOTALS="$fs_total_bytes,$fs_total_bytes,$fs_total_bytes" \
    TEST_DF_USEDS="$fs_used_bytes,$fs_used_bytes,$((fs_used_bytes - 15000))" \
    TEST_DF_INDEX_FILE="$df_index_file" \
    TEST_JOURNALCTL_LOG="$journalctl_log" \
    TEST_TMPFILES_LOG="$tmpfiles_log" \
    TEST_GC_LOG="$gc_log" \
    bash "$cleanup_helper" >"$output_file" 2>&1
}

# Below threshold: only the check event, no cleanup.
run_cleanup 84000
if [[ -s "$journalctl_log" || -s "$tmpfiles_log" || -s "$gc_log" ]]; then
  echo "❌ Disk cleanup ran actions below the configured trigger." >&2
  exit 1
fi
jq -s -e '
  length == 1
  and .[0].event == "disk_cleanup_check"
  and .[0].decision == "skip"
  and .[0].trigger_percent == 85
  and .[0].max_used_percent == 84
  and .[0].nix_gc_enabled == true
' "$output_file" >/dev/null || {
  echo "❌ Disk cleanup did not report its below-threshold decision." >&2
  cat "$output_file" >&2
  exit 1
}

# At threshold: run all three conservative actions and report freed bytes.
run_cleanup 85000
if [[ "$(<"$journalctl_log")" != '--vacuum-time=7d' ]]; then
  echo "❌ Disk cleanup did not vacuum the journal to the configured window." >&2
  cat "$journalctl_log" >&2
  exit 1
fi
if [[ "$(<"$tmpfiles_log")" != '--clean' ]]; then
  echo "❌ Disk cleanup did not run age-based tmpfiles cleanup." >&2
  cat "$tmpfiles_log" >&2
  exit 1
fi
if [[ "$(<"$gc_log")" != '--delete-older-than 45d' ]]; then
  echo "❌ Disk cleanup did not run the expected 45-day store collection." >&2
  cat "$gc_log" >&2
  exit 1
fi
jq -s -e '
  map(.event) == ["disk_cleanup_check", "disk_cleanup_recheck", "disk_cleanup_started", "disk_cleanup_completed"]
  and .[0].decision == "cleanup"
  and .[0].store_monitored == true
  and .[2].actions == ["journald_vacuum", "tmpfiles_clean", "nix_store_gc"]
  and .[3].used_before == 85000
  and .[3].used_after == 70000
  and .[3].freed_bytes == 15000
  and .[3].actions == [
    {name:"journald_vacuum",status:0},
    {name:"tmpfiles_clean",status:0},
    {name:"nix_store_gc",status:0}
  ]
' "$output_file" >/dev/null || {
  echo "❌ Disk cleanup telemetry is incomplete or incorrect." >&2
  cat "$output_file" >&2
  exit 1
}

# Store on an unmonitored filesystem: nix GC action is skipped.
: >"$gc_log"
printf '0\n' >"$df_index_file"
TEST_STORE_DEV=99 TEST_MONITOR_DEV=1 run_cleanup 85000
if [[ -s "$gc_log" ]]; then
  echo "❌ Disk cleanup ran nix GC for an unmonitored store filesystem." >&2
  cat "$gc_log" >&2
  exit 1
fi
jq -s -e '
  .[0].store_monitored == false
  and .[0].nix_gc_enabled == false
  and .[2].actions == ["journald_vacuum", "tmpfiles_clean"]
' "$output_file" >/dev/null || {
  echo "❌ Disk cleanup did not gate nix GC on the store filesystem being monitored." >&2
  cat "$output_file" >&2
  exit 1
}

# Maintenance lock busy: measure, defer, exit 75, never clean.
printf '0\n' >"$df_index_file"
lock_status=0
TEST_FLOCK_BUSY=1 run_cleanup 85000 || lock_status=$?
if ((lock_status != 75)) || [[ -s "$journalctl_log" ]]; then
  echo "❌ Disk cleanup did not defer safely when another maintenance job held the lock." >&2
  cat "$output_file" >&2
  exit 1
fi
jq -s -e '
  map(.event) == ["disk_cleanup_check", "disk_cleanup_deferred"]
  and .[0].decision == "cleanup"
' "$output_file" >/dev/null || {
  echo "❌ Disk cleanup did not measure and report pressure before lock deferral." >&2
  cat "$output_file" >&2
  exit 1
}

# Action failure: keep trying remaining actions, then fail with the status.
printf '0\n' >"$df_index_file"
action_failure_status=0
TEST_JOURNALCTL_FAIL=1 run_cleanup 85000 || action_failure_status=$?
if ((action_failure_status != 42)); then
  echo "❌ Disk cleanup did not preserve the failing action status." >&2
  exit 1
fi
if [[ "$(<"$tmpfiles_log")" != '--clean' || "$(<"$gc_log")" != '--delete-older-than 45d' ]]; then
  echo "❌ Disk cleanup aborted remaining actions after one failure." >&2
  exit 1
fi
jq -s -e '
  .[-2].event == "disk_cleanup_completed"
  and (. [-2].actions | map(.name) == ["journald_vacuum", "tmpfiles_clean", "nix_store_gc"])
  and .[-2].actions[0].status == 42
  and .[-2].actions[1].status == 0
  and .[-2].actions[2].status == 0
  and .[-1].event == "disk_cleanup_failed"
  and .[-1].exit_status == 42
  and ([.[] | select(.event == "disk_cleanup_action_failed")] | length) == 1
  and ([.[] | select(.event == "disk_cleanup_action_failed")][0].action == "journald_vacuum")
  and (([.[] | select(.event == "disk_cleanup_action_failed")][0].output_base64 | @base64d) | contains("cannot archive journal"))
' "$output_file" >/dev/null || {
  echo "❌ Disk cleanup failure telemetry omitted the failing action diagnostic." >&2
  cat "$output_file" >&2
  exit 1
}

# Invalid configuration is rejected before any cleanup runs.
for bad_env in \
  DISK_CLEANUP_TRIGGER_PERCENT=0 \
  DISK_CLEANUP_TRIGGER_PERCENT=101 \
  DISK_CLEANUP_JOURNAL_VACUUM_TIME=7 \
  DISK_CLEANUP_JOURNAL_VACUUM_TIME=7x \
  DISK_CLEANUP_NIX_GC_RETENTION_DAYS=0; do
  : >"$journalctl_log"
  : >"$tmpfiles_log"
  : >"$gc_log"
  printf '0\n' >"$df_index_file"
  if env "$bad_env" \
      PATH="$mock_bin:$PATH" \
      INVOCATION_ID=0123456789abcdef \
      TEST_JOURNALCTL_LOG="$journalctl_log" \
      TEST_TMPFILES_LOG="$tmpfiles_log" \
      TEST_GC_LOG="$gc_log" \
      bash "$cleanup_helper" >"$output_file" 2>&1; then
    echo "❌ Disk cleanup accepted invalid configuration: ${bad_env}." >&2
    exit 1
  fi
  if [[ -s "$journalctl_log" || -s "$tmpfiles_log" || -s "$gc_log" ]]; then
    echo "❌ Disk cleanup ran actions after rejecting invalid configuration: ${bad_env}." >&2
    exit 1
  fi
  jq -s -e '
    .[-1].event == "disk_cleanup_failed"
    and .[-1].exit_status == 64
  ' "$output_file" >/dev/null || {
    echo "❌ Disk cleanup invalid-config rejection is not reported as exit 64: ${bad_env}." >&2
    cat "$output_file" >&2
    exit 1
  }
done

host="$(test_default_host)"
service_json="$(
  NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
    let
      flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
      cfg = (builtins.getAttr host flake.nixosConfigurations).config;
      service = cfg.systemd.services.nixhomeserver-disk-cleanup;
      timer = cfg.systemd.timers.nixhomeserver-disk-cleanup;
      diskCleanup = (builtins.getAttr host flake.lib.nixhomeserverSettings).diskCleanup;
    in {
      inherit (service) environment;
      execStart = toString service.serviceConfig.ExecStart;
      successExitStatus = service.serviceConfig.SuccessExitStatus;
      execStopPost = toString service.serviceConfig.ExecStopPost;
      onFailure = service.unitConfig.OnFailure;
      onFailureJobMode = service.unitConfig.OnFailureJobMode;
      onCalendar = timer.timerConfig.OnCalendar;
      persistent = timer.timerConfig.Persistent;
      randomizedDelay = timer.timerConfig.RandomizedDelaySec;
      inherit diskCleanup;
    }
  '
)"

jq -e '
  .environment.DISK_CLEANUP_TRIGGER_PERCENT == "85"
  and .environment.DISK_CLEANUP_JOURNAL_VACUUM_TIME == "7d"
  and .environment.DISK_CLEANUP_NIX_GC_RETENTION_DAYS == "45"
  and .environment.DISK_CLEANUP_MONITOR_PATHS == "/"
  and (.execStart | contains("nixhomeserver-disk-space-cleanup"))
  and (.successExitStatus | index(75) != null)
  and (.execStopPost | contains("disk_cleanup_failed"))
  and .onFailure == ["nixhomeserver-failure-alert@%n.service"]
  and .onFailureJobMode == "replace-irreversibly"
  and .onCalendar == "*:0/30:00"
  and .persistent == true
  and .randomizedDelay == "10m"
  and .diskCleanup.enable == true
  and .diskCleanup.triggerPercent == 85
  and .diskCleanup.monitorPaths == ["/"]
  and .diskCleanup.journalVacuumTime == "7d"
' <<<"$service_json" >/dev/null || {
  echo "❌ Evaluated disk cleanup service does not match the configured policy." >&2
  jq . <<<"$service_json" >&2
  exit 1
}

invalid_log="$test_dir/invalid-settings.log"
for invalid_field in triggerPercent journalVacuumTime monitorPaths enable; do
  if NIXHOMESERVER_INVALID_DISK_CLEANUP_FIELD="$invalid_field" nix eval --impure --raw --expr '
      let
        flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
        lib = flake.inputs.nixpkgs.lib;
        base = import ./vars.nix { inherit lib; };
        field = builtins.getEnv "NIXHOMESERVER_INVALID_DISK_CLEANUP_FIELD";
        invalid = base // {
          diskCleanup = base.diskCleanup // {
            ${field} = if field == "triggerPercent" then 0
                       else if field == "journalVacuumTime" then "7"
                       else if field == "monitorPaths" then [ ]
                       else "yes";
          };
        };
      in
      (import ./lib/validate-host-settings.nix {
        inherit lib;
        hostName = base.hostname;
        settings = invalid;
      }).hostname
    ' >"$invalid_log" 2>&1; then
    echo "❌ Host validation accepted invalid diskCleanup.${invalid_field}." >&2
    exit 1
  fi
  case "$invalid_field" in
    triggerPercent) expected_error="system.diskCleanup.triggerPercent must be an integer from 1 through 100" ;;
    journalVacuumTime) expected_error="system.diskCleanup.journalVacuumTime must look like" ;;
    monitorPaths) expected_error="system.diskCleanup.monitorPaths must be a non-empty list" ;;
    enable) expected_error="system.diskCleanup.enable must be a boolean" ;;
  esac
  if ! rg -Fq "$expected_error" "$invalid_log"; then
    echo "❌ Invalid ${invalid_field} failed without actionable guidance." >&2
    cat "$invalid_log" >&2
    exit 1
  fi
done

for invalid_field in triggerPercent journalVacuumTime monitorPaths; do
  if NIXHOMESERVER_INVALID_LOCAL_DISK_CLEANUP_FIELD="$invalid_field" nix eval --impure --raw --expr '
      let
        flake = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
        lib = flake.inputs.nixpkgs.lib;
        base = import ./vars.nix { inherit lib; };
        field = builtins.getEnv "NIXHOMESERVER_INVALID_LOCAL_DISK_CLEANUP_FIELD";
        invalid = base // {
          localDiskCleanup = base.localDiskCleanup // {
            ${field} = if field == "triggerPercent" then 0
                       else if field == "journalVacuumTime" then "7"
                       else [ ];
          };
        };
      in
      (import ./lib/validate-host-settings.nix {
        inherit lib;
        hostName = base.hostname;
        settings = invalid;
      }).hostname
    ' >"$invalid_log" 2>&1; then
    echo "❌ Host validation accepted invalid localDiskCleanup.${invalid_field}." >&2
    exit 1
  fi
  case "$invalid_field" in
    triggerPercent) expected_error="system.localDiskCleanup.triggerPercent must be an integer from 1 through 100" ;;
    journalVacuumTime) expected_error="system.localDiskCleanup.journalVacuumTime must look like" ;;
    monitorPaths) expected_error="system.localDiskCleanup.monitorPaths must be a non-empty list" ;;
  esac
  if ! rg -Fq "$expected_error" "$invalid_log"; then
    echo "❌ Invalid localDiskCleanup ${invalid_field} failed without actionable guidance." >&2
    cat "$invalid_log" >&2
    exit 1
  fi
done

echo "✅ Capacity-triggered conservative disk space cleanup tests passed."