#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp rg

echo "ℹ️ Checking runtime-readiness interface…"
require_fixed scripts/runtime-readiness.sh 'source "$script_dir/lib-runtime-health.sh"' \
  "runtime-readiness.sh must source the shared runtime-health helper."
require_fixed scripts/runtime-readiness.sh 'source "$script_dir/lib-storage-health.sh"' \
  "runtime-readiness.sh must source the shared SMART helper."
require_fixed scripts/runtime-readiness.sh '--profile manual|deploy|monitor' \
  "runtime-readiness.sh must expose explicit runtime-health profiles."
require_fixed scripts/runtime-readiness.sh '--format text|json' \
  "runtime-readiness.sh must support text and JSON output."
require_fixed scripts/runtime-readiness.sh '--deep' \
  "runtime-readiness.sh must expose deep runtime probes."
require_fixed scripts/runtime-readiness.sh '--require-online-zpool' \
  "runtime-readiness.sh must keep the strict deploy compatibility alias."
require_fixed scripts/runtime-readiness.sh 'runtime_health_load_snapshot' \
  "runtime-readiness.sh must evaluate one shared runtime-health snapshot per run."

echo "ℹ️ Checking SMART helper fixture behavior…"
fixture_dir="$TESTS_REPO_ROOT/tests/fixtures/storage-health"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/smartctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
device="${!#}"
base="$(basename "$device")"
cat "${STORAGE_HEALTH_FIXTURE_DIR}/${base}.smartctl"
EOF
chmod +x "$tmpdir/smartctl"

cat >"$tmpdir/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ -n "${STORAGE_HEALTH_JOURNAL_FIXTURE:-}" ]]; then
  cat "$STORAGE_HEALTH_JOURNAL_FIXTURE"
fi
EOF
chmod +x "$tmpdir/journalctl"

cat >"$tmpdir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-u" ]]; then
  shift 2
fi
"$@"
EOF
chmod +x "$tmpdir/sudo"

warn_output="$(
  PATH="$tmpdir:$PATH" \
    STORAGE_HEALTH_FIXTURE_DIR="$fixture_dir" \
    scripts/lib-storage-health.sh --mode warn \
      clean=/dev/disk/by-id/clean \
      aging=/dev/disk/by-id/aging
)"
require_match <(printf '%s\n' "$warn_output") '^OK[[:space:]]+clean[[:space:]]+/dev/disk/by-id/clean$' \
  "SMART helper must report clean disks as OK."
require_match <(printf '%s\n' "$warn_output") '^WARN[[:space:]]+aging[[:space:]]+/dev/disk/by-id/aging$' \
  "SMART helper must warn on non-critical degradation counters."
require_match <(printf '%s\n' "$warn_output") 'Reallocated_Sector_Ct=8' \
  "SMART helper must surface warning counters in operator output."

set +e
critical_output="$(
  PATH="$tmpdir:$PATH" \
    STORAGE_HEALTH_FIXTURE_DIR="$fixture_dir" \
    scripts/lib-storage-health.sh --mode strict \
      critical=/dev/disk/by-id/critical 2>&1
)"
critical_status=$?
set -e
require_json_equal "$critical_status" "1" \
  "SMART helper strict mode must fail on critical degradation counters."
require_match <(printf '%s\n' "$critical_output") '^CRITICAL[[:space:]]+critical[[:space:]]+/dev/disk/by-id/critical$' \
  "SMART helper must report critical disks clearly."
require_match <(printf '%s\n' "$critical_output") 'Offline_Uncorrectable=6' \
  "SMART helper must surface critical media errors in operator output."

transport_output="$(
  PATH="$tmpdir:$PATH" \
    STORAGE_HEALTH_FIXTURE_DIR="$fixture_dir" \
    STORAGE_HEALTH_JOURNAL_FIXTURE="$fixture_dir/transport.journal" \
    scripts/lib-storage-health.sh --mode warn \
      transport=/dev/disk/by-id/transport
)"
require_match <(printf '%s\n' "$transport_output") '^CRITICAL[[:space:]]+transport[[:space:]]+/dev/disk/by-id/transport$' \
  "SMART helper must escalate recent transport failures."
require_match <(printf '%s\n' "$transport_output") 'recent kernel transport errors' \
  "SMART helper must explain transport-related critical results."

echo "ℹ️ Checking runtime-readiness profiles with snapshot fixtures…"
runtime_root="${tmpdir}/runtime"
runtime_bin="${runtime_root}/bin"
mount_root="${runtime_root}/mounts"
metadata_root="${runtime_root}/metadata"
dumps_root="${runtime_root}/dumps"
db_root="${runtime_root}/db"
snapshot_file="${runtime_root}/snapshot.json"
mkdir -p \
  "$runtime_bin" \
  "${mount_root}/data/paperless/archive/.hist" \
  "${mount_root}/data/shared/app-state" \
  "${mount_root}/data/users" \
  "$metadata_root" \
  "$dumps_root" \
  "$db_root"
touch "${db_root}/mail-archive-ui.sqlite3"

cat >"$snapshot_file" <<EOF
{
  "host": {
    "hostname": "server",
    "domain": "example.test",
    "lanDnsDomain": "home.arpa",
    "dnsMode": "split-horizon",
    "serverLanIP": "192.168.8.12",
    "nbIP": "100.64.0.10",
    "localDnsPrivateAnswer": "192.168.8.12"
  },
  "services": {
    "requiredUnits": ["copyparty.service"],
    "edgeHttp": [
      { "name": "files", "url": "https://files.example.test/", "expected": [200, 302, 303, 401, 403] }
    ],
    "internalHttp": [
      { "name": "copyparty", "url": "http://127.0.0.1:3923/", "expected": [200, 302, 401, 403] }
    ],
    "dns": {
      "resolve": ["example.com"],
      "private": [
        { "host": "files.example.test", "expected": "192.168.8.12" }
      ],
      "splitHorizon": {
        "private": [
          { "host": "server.home.arpa", "expected": "192.168.8.12" }
        ],
        "ptr": [
          { "ip": "192.168.8.12", "expected": "server.home.arpa" }
        ]
      },
      "netbirdOnly": {
        "public": []
      }
    }
  },
  "storage": {
    "dataPool": {
      "name": "data",
      "mountPoint": "${mount_root}/data",
      "datasetMounts": [
        "${mount_root}/data/users",
        "${mount_root}/data/shared"
      ]
    },
    "monitoredDisks": [
      { "label": "disk1", "device": "/dev/disk/by-id/disk1" }
    ],
    "coldStoragePoolNames": []
  },
  "persistence": {
    "enabled": false,
    "directories": [],
    "files": []
  },
  "backup": {
    "service": "restic-backups-system-state.service",
    "timer": "restic-backups-system-state.timer",
    "selectionFile": "${runtime_root}/selected-device",
    "mountPoint": "${mount_root}/backup",
    "repositoryPath": "${mount_root}/backup/restic/system-state",
    "metadataRoot": "${metadata_root}",
    "timestampFile": "${metadata_root}/timestamp.txt",
    "appStateFile": "${metadata_root}/app-state-roots.tsv",
    "criticalPathsFile": "${metadata_root}/critical-paths.tsv",
    "zpoolStatusFile": "${metadata_root}/zpool-status.txt",
    "zpoolListFile": "${metadata_root}/zpool-list.txt",
    "zfsListFile": "${metadata_root}/zfs-list.txt",
    "postgresqlDumpFile": "${dumps_root}/postgresql.sql",
    "maxAgeSeconds": 129600
  },
  "appState": {
    "entries": [
      {
        "app": "copyparty",
        "component": "app",
        "stateRoot": "${mount_root}/data/shared/app-state",
        "payloadRoots": ["${mount_root}/data/shared"]
      }
    ],
    "criticalPaths": [
      "${mount_root}/data",
      "${mount_root}/data/shared"
    ],
    "requiredPaths": [
      {
        "label": "copyparty-archive-metadata",
        "path": "${mount_root}/data/paperless/archive/.hist"
      }
    ]
  },
  "databases": {
    "sqliteBinary": "${runtime_bin}/sqlite3",
    "sqlite": [
      { "name": "mail-archive-ui", "path": "${db_root}/mail-archive-ui.sqlite3" }
    ],
    "postgresql": {
      "enabled": true,
      "dataDir": "/var/lib/postgresql",
      "pgIsReadyBinary": "${runtime_bin}/pg_isready"
    }
  }
}
EOF

printf '%s\n' '/dev/disk/by-id/backup-target' >"${runtime_root}/selected-device"
printf '%s\n' '2026-01-01T00:00:00Z' >"${metadata_root}/timestamp.txt"

cat >"$runtime_bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$runtime_bin/nix"

cat >"$runtime_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '200'
EOF
chmod +x "$runtime_bin/curl"

cat >"$runtime_bin/host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

name="$1"
case "$name" in
  example.com)
    printf '%s has address 93.184.216.34\n' "$name"
    ;;
  files.example.test|server.home.arpa)
    printf '%s has address 192.168.8.12\n' "$name"
    ;;
  192.168.8.12)
    printf '12.8.168.192.in-addr.arpa domain name pointer server.home.arpa.\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$runtime_bin/host"

cat >"$runtime_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="$1"
case "$cmd" in
  is-active)
    case "$2" in
      copyparty.service|restic-backups-system-state.timer)
        printf 'active\n'
        ;;
      *)
        printf 'inactive\n'
        ;;
    esac
    ;;
  is-enabled)
    case "$2" in
      restic-backups-system-state.timer)
        printf 'enabled\n'
        ;;
      *)
        printf 'disabled\n'
        ;;
    esac
    ;;
  show)
    printf 'success\n'
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$runtime_bin/systemctl"

cat >"$runtime_bin/findmnt" <<EOF
#!/usr/bin/env bash
set -euo pipefail

target="\${!#}"
if printf '%s\n' "\$*" | grep -q 'FSTYPE'; then
  case "\$target" in
    "${mount_root}/data"|\
    "${mount_root}/data/media"|\
    "${mount_root}/data/users"|\
    "${mount_root}/data/shared")
      printf 'zfs\n'
      ;;
    *)
      exit 1
      ;;
  esac
elif printf '%s\n' "\$*" | grep -q 'SOURCE'; then
  exit 1
else
  exit 1
fi
EOF
chmod +x "$runtime_bin/findmnt"

cat >"$runtime_bin/smartctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cat "${fixture_dir}/clean.smartctl"
EOF
chmod +x "$runtime_bin/smartctl"

cat >"$runtime_bin/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$runtime_bin/journalctl"

cat >"$runtime_bin/zpool" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "list" && "$2" == "-H" && "$3" == "-o" && "$4" == "health" ]]; then
  printf '%s\n' "${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

if [[ "$1" == "status" ]]; then
  printf 'pool: %s\nstate: %s\n' "$2" "${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

exit 1
EOF
chmod +x "$runtime_bin/zpool"

cat >"$runtime_bin/zfs" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" == "list" ]]; then
  printf 'data\t%s/data\n' "${mount_root}"
  printf 'data/media\t%s/data/media\n' "${mount_root}"
  printf 'data/users\t%s/data/users\n' "${mount_root}"
  printf 'data/shared\t%s/data/shared\n' "${mount_root}"
  exit 0
fi

exit 1
EOF
chmod +x "$runtime_bin/zfs"

cat >"$runtime_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift 3
exec "$@"
EOF
chmod +x "$runtime_bin/runuser"

cat >"$runtime_bin/sqlite3" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ok\n'
EOF
chmod +x "$runtime_bin/sqlite3"

cat >"$runtime_bin/pg_isready" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$runtime_bin/pg_isready"

manual_env=(
  "PATH=$runtime_bin:$tmpdir:$PATH"
  "RUNTIME_READINESS_REPO_ROOT=$TESTS_REPO_ROOT"
  "RUNTIME_HEALTH_SNAPSHOT_JSON_FILE=$snapshot_file"
)

set +e
manual_output="$(
  env "${manual_env[@]}" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    scripts/runtime-readiness.sh 2>&1
)"
manual_status=$?
set -e
require_json_equal "$manual_status" "0" \
  "runtime-readiness.sh must pass by default when a mirrored pool is DEGRADED but mounted."
require_match <(printf '%s\n' "$manual_output") '^⚠️  zpool health DEGRADED:' \
  "runtime-readiness.sh must surface degraded ZFS health in operator output."
require_match <(printf '%s\n' "$manual_output") 'continuing because the mirrored pool is still available, but redundancy is lost' \
  "runtime-readiness.sh must explain why degraded mirrored storage still passes by default."
require_match <(printf '%s\n' "$manual_output") 'backup state: backup metadata is stale, but the removable target is absent' \
  "runtime-readiness.sh must warn when backups are stale but the removable target is absent."

monitor_json="$(
  env "${manual_env[@]}" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    scripts/runtime-readiness.sh --profile monitor --format json
)"
require_json_equal "$(jq -r '.profile' <<<"$monitor_json")" "monitor" \
  "runtime-readiness.sh JSON output must report the selected profile."
require_json_equal "$(jq -r '.backup.severity' <<<"$monitor_json")" "WARN" \
  "runtime-readiness.sh must downgrade stale removable-backup state to WARN when the target is absent."
require_json_equal "$(jq -r '.zfs.runtimeState' <<<"$monitor_json")" "degraded" \
  "runtime-readiness.sh monitor output must preserve the degraded runtime state."

set +e
deploy_output="$(
  env "${manual_env[@]}" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    scripts/runtime-readiness.sh --profile deploy 2>&1
)"
deploy_status=$?
set -e
require_json_equal "$deploy_status" "1" \
  "runtime-readiness.sh deploy profile must fail when the mirrored pool is DEGRADED."
require_match <(printf '%s\n' "$deploy_output") 'deploy profile requires ONLINE zpool health' \
  "runtime-readiness.sh deploy profile must explain the ONLINE-only guardrail."

printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${metadata_root}/timestamp.txt"
touch "${metadata_root}/app-state-roots.tsv" \
  "${metadata_root}/critical-paths.tsv" \
  "${metadata_root}/zpool-status.txt" \
  "${metadata_root}/zpool-list.txt" \
  "${metadata_root}/zfs-list.txt" \
  "${dumps_root}/postgresql.sql"

deep_json="$(
  env "${manual_env[@]}" \
    scripts/runtime-readiness.sh --profile manual --deep --format json
)"
require_json_equal "$(jq -r '.overallSeverity' <<<"$deep_json")" "OK" \
  "runtime-readiness.sh deep checks must pass when database and backup fixtures are healthy."
require_json_equal "$(jq -r '[.deepChecks[] | select(.kind == "sqlite" and .severity == "OK")] | length' <<<"$deep_json")" "1" \
  "runtime-readiness.sh deep mode must run sqlite quick_check probes."
require_json_equal "$(jq -r '[.deepChecks[] | select(.kind == "postgresql" and .severity == "OK")] | length' <<<"$deep_json")" "2" \
  "runtime-readiness.sh deep mode must validate PostgreSQL connectivity and dump freshness."

echo "✅ Runtime readiness tests passed."
