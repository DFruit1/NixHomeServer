#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp rg

echo "ℹ️ Checking runtime readiness profiles with dynamic storage fixtures…"
fixture_dir="$TESTS_REPO_ROOT/scripts/tests/fixtures/storage-health"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
bash_path="$(command -v bash)"

runtime_root="${tmpdir}/runtime"
runtime_bin="${runtime_root}/bin"
mount_root="${runtime_root}/mounts"
metadata_root="${runtime_root}/metadata"
dumps_root="${runtime_root}/dumps"
db_root="${runtime_root}/db"
snapshot_file="${runtime_root}/snapshot.json"
device_root="${runtime_root}/devices"
dev_disk_root="${runtime_root}/dev-disk"
by_id_dir="${dev_disk_root}/by-id"
bootstrap_state_file="${runtime_root}/bootstrap-state.json"
helper_results_file="${runtime_root}/browser-helper-results.json"
mail_archive_data_root="${runtime_root}/mail-archive-ui"
mail_archive_runtime_dir="${runtime_root}/run-mail-archive-ui"
mail_archive_lock_dir="${mail_archive_data_root}/locks"
mail_archive_store_root="${mount_root}/data/users"
mail_archive_hidden_sync_root="${mail_archive_store_root}/dsaw/emails/.internal-sync/personal-gmail--1"
mail_archive_visible_mirror_dir="${mail_archive_store_root}/dsaw/emails/personal-gmail-inbox/2024/04"
mail_archive_visible_mirror_file="${mail_archive_visible_mirror_dir}/2024-04-18 14-32 - Runtime Probe [abc12345].eml"

system_disk_actual="${device_root}/system-disk"
system_part_actual="${device_root}/system-disk-part1"
data_a_actual="${device_root}/data-a"
data_a_part_actual="${device_root}/data-a-part1"
data_b_actual="${device_root}/data-b"
data_b_part_actual="${device_root}/data-b-part1"
retired_actual="${device_root}/retired-a"
usb_actual="${device_root}/usb-backup"
usb_part_actual="${device_root}/usb-backup-part1"

mkdir -p \
  "$runtime_bin" \
  "${mount_root}/data/paperless/archive/.hist" \
  "${mount_root}/data/shared/app-state" \
  "${mount_root}/data/users/dsaw/uploads" \
  "${mail_archive_hidden_sync_root}/maildir/cur" \
  "$mail_archive_visible_mirror_dir" \
  "$metadata_root" \
  "$dumps_root" \
  "$db_root" \
  "$mail_archive_data_root" \
  "$mail_archive_runtime_dir" \
  "$mail_archive_lock_dir" \
  "$device_root" \
  "$by_id_dir"

touch \
  "$mail_archive_visible_mirror_file" \
  "${mail_archive_data_root}/mail-archive-ui.sqlite3" \
  "$system_disk_actual" \
  "$system_part_actual" \
  "$data_a_actual" \
  "$data_a_part_actual" \
  "$data_b_actual" \
  "$data_b_part_actual" \
  "$retired_actual" \
  "$usb_actual" \
  "$usb_part_actual"
chmod 0644 "$mail_archive_visible_mirror_file"

ln -s "$system_disk_actual" "$by_id_dir/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"
ln -s "$system_part_actual" "$by_id_dir/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E-part1"
ln -s "$data_a_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV3997N"
ln -s "$data_a_part_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV3997N-part1"
ln -s "$data_b_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV37712"
ln -s "$data_b_part_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV37712-part1"
ln -s "$retired_actual" "$by_id_dir/ata-HGST_HUS726T4TALA6L4_V1JAKPNH"
ln -s "$usb_actual" "$by_id_dir/usb-Samsung_PSSD_T7_S7MLNS0Y711062N"
ln -s "$usb_part_actual" "$by_id_dir/usb-Samsung_PSSD_T7_S7MLNS0Y711062N-part1"
ln -s "$usb_part_actual" "$by_id_dir/wwn-0xbackup-usb-part1"

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
    "requiredUnits": ["copyparty.service", "mail-archive-ui.service"],
    "edgeHttp": [
      { "name": "uploads", "url": "https://uploads.example.test/", "expected": [200, 302, 303, 401, 403] },
      { "name": "files", "url": "https://files.example.test/", "expected": [200, 302, 303] }
    ],
    "internalHttp": [
      { "name": "copyparty", "url": "http://127.0.0.1:3923/", "expected": [200, 302, 401, 403] },
      { "name": "mail-archive-ui-healthz", "url": "http://127.0.0.1:9011/healthz", "expected": [200] }
    ],
    "dns": {
      "resolve": ["example.com"],
      "private": [
        { "host": "files.example.test", "expected": "192.168.8.12" }
      ],
      "splitHorizon": {
        "private": [
          { "host": "uploads.example.test", "expected": "192.168.8.12" },
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
    "systemDisk": {
      "diskId": "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E",
      "device": "${by_id_dir}/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"
    },
    "dataPool": {
      "name": "data",
      "mountPoint": "${mount_root}/data",
      "datasetMounts": [
        "${mount_root}/data/users",
        "${mount_root}/data/shared"
      ]
    }
  },
  "uploadAccess": {
    "copyparty": {
      "serviceUser": "copyparty",
      "requiredGroup": "users",
      "uploadRootsParent": "${mount_root}/data/users",
      "uploadSubdir": "uploads"
    }
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
      },
      {
        "label": "mail-archive-ui-data",
        "path": "${mail_archive_data_root}"
      },
      {
        "label": "mail-archive-ui-runtime",
        "path": "${mail_archive_runtime_dir}"
      },
      {
        "label": "mail-archive-ui-locks",
        "path": "${mail_archive_lock_dir}"
      },
      {
        "label": "mail-archive-ui-store-root",
        "path": "${mail_archive_store_root}"
      },
      {
        "label": "mail-archive-hidden-sync-root",
        "path": "${mail_archive_hidden_sync_root}"
      }
    ]
  },
  "databases": {
    "sqliteBinary": "${runtime_bin}/sqlite3",
    "sqlite": [
      { "name": "mail-archive-ui", "path": "${mail_archive_data_root}/mail-archive-ui.sqlite3" }
    ],
    "postgresql": {
      "enabled": true,
      "dataDir": "/var/lib/postgresql",
      "pgIsReadyBinary": "${runtime_bin}/pg_isready",
      "psqlBinary": "${runtime_bin}/psql"
    }
  },
  "immich": {
    "enabled": true,
    "databaseName": "immich",
    "machineLearningUrl": "http://127.0.0.1:3003",
    "smartSearchCoverageWarnPercent": 95
  },
  "accessChecks": {
    "bootstrapStateFile": "${bootstrap_state_file}",
    "browserHelper": "scripts/helpers/runtime-access-browser-check.mjs",
    "canaries": [
      {
        "accountId": "canary-files",
        "displayName": "Runtime Access Canary",
        "mailAddress": "runtime-canary-files@example.test",
        "groups": [
          "users",
          "user-files",
          "shared-files-read-write-access",
          "paperless-users",
          "immich-users",
          "audiobookshelf-users",
          "kavita-users",
          "glances-users",
          "mail-archive-users",
          "metube-users"
        ],
        "passwordSecret": "runtimeCanaryFilesPassword",
        "expectedApps": [
          { "name": "uploads", "kind": "oauth2-proxy", "expectedLandingUrl": "https://uploads.example.test/" },
          { "name": "files", "kind": "oidc-direct", "expectedLandingUrl": "https://files.example.test/" }
        ]
      }
    ],
    "apps": [
      {
        "name": "uploads",
        "kind": "oauth2-proxy",
        "entryUrl": "https://uploads.example.test/",
        "expectedLandingUrl": "https://uploads.example.test/",
        "allowedGroups": ["user-files"],
        "localUnauthCheck": {
          "host": "uploads.example.test",
          "path": "/",
          "expected": [302, 303],
          "redirectPrefix": "https://id.example.test/ui/oauth2"
        },
        "verification": {
          "finalUrlPrefix": "https://uploads.example.test/",
          "markerText": "copyparty"
        }
      },
      {
        "name": "files",
        "kind": "oidc-direct",
        "entryUrl": "https://files.example.test/",
        "expectedLandingUrl": "https://files.example.test/",
        "allowedGroups": ["user-files", "shared-files-read-write-access"],
        "localUnauthCheck": {
          "host": "files.example.test",
          "path": "/login",
          "expected": [302, 303],
          "redirectPrefix": "/api/auth/oidc/login"
        },
        "verification": {
          "finalUrlPrefix": "https://files.example.test/",
          "markerText": "Files"
        }
      }
    ]
  },
  "mailArchiveFilebrowser": {
    "serviceUser": "filebrowser-quantum",
    "storeRoot": "${mail_archive_store_root}"
  }
}
EOF

printf '%s\n' "${by_id_dir}/usb-selected-backup-part1" >"${runtime_root}/selected-device"
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

headers_file=""
url=""

while (($# > 0)); do
  case "$1" in
    -D)
      headers_file="$2"
      shift 2
      ;;
    -o|-w|--resolve|--max-time)
      shift 2
      ;;
    -s|-k|-sk|-ks|-I|-L|-f|-S|-fsS|-sfS)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

code="200"
location=""
case "$url" in
  http://127.0.0.1:3003/ping)
    printf 'pong'
    exit 0
    ;;
  https://uploads.example.test/)
    code="302"
    location="https://id.example.test/ui/oauth2?client_id=oauth2-proxy"
    ;;
  https://files.example.test/login)
    code="302"
    location="/api/auth/oidc/login?next=%2F"
    ;;
esac

if [[ -n "$headers_file" ]]; then
  {
    printf 'HTTP/1.1 %s Test\r\n' "$code"
    if [[ -n "$location" ]]; then
      printf 'Location: %s\r\n' "$location"
    fi
    printf '\r\n'
  } >"$headers_file"
fi

printf '%s' "$code"
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
  files.example.test|uploads.example.test|server.home.arpa)
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
      copyparty.service|mail-archive-ui.service|restic-backups-system-state.timer)
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

cat >"$runtime_bin/blkid" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$runtime_bin/blkid"

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

if [[ "\${1:-}" == "--scan-open" ]]; then
  cat <<'SCAN'
${system_disk_actual} -d sat # system disk
${data_a_actual} -d sat # data disk a
${data_b_actual} -d sat # data disk b
${retired_actual} -d sat # retired internal disk
${usb_actual} -d sntasmedia # usb backup disk
SCAN
  exit 0
fi

device="\${!#}"
actual="\$(readlink -f "\$device" 2>/dev/null || printf '%s' "\$device")"
base="\$(basename "\$actual")"

if [[ "\${1:-}" == "-d" && "\${3:-}" == "-t" ]]; then
  echo "Self-test started for \$base"
  exit 0
fi

cat "${fixture_dir}/clean.smartctl"
EOF
chmod +x "$runtime_bin/smartctl"

cat >"$runtime_bin/journalctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$runtime_bin/journalctl"

cat >"$runtime_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-u" ]]; then
  shift 2
fi
if [[ "${1:-}" == "test" && "${2:-}" == "!" && "${3:-}" == "-x" && "${4:-}" == *"/emails/.internal-sync" ]]; then
  exit 0
fi
"$@"
EOF
chmod +x "$runtime_bin/sudo"

cat >"$runtime_bin/getent" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "group" && "${2:-}" == "users" ]]; then
  printf 'users:x:100:copyparty,filebrowser-quantum,metube\n'
  exit 0
fi

exit 2
EOF
chmod +x "$runtime_bin/getent"

cat >"$runtime_bin/id" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-nG" && "${2:-}" == "copyparty" ]]; then
  printf 'copyparty users\n'
  exit 0
fi

exit 1
EOF
chmod +x "$runtime_bin/id"

cat >"$runtime_bin/host" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "192.168.8.12" ]]; then
  printf '%s.in-addr.arpa domain name pointer server.home.arpa.\n' "$1"
elif [[ "$1" == "example.com" ]]; then
  printf '%s has address 192.0.2.10\n' "$1"
else
  printf '%s has address 192.168.8.12\n' "$1"
fi
EOF
chmod +x "$runtime_bin/host"

cat >"$runtime_bin/zpool" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" == "list" && "\$2" == "-H" && "\$3" == "-o" && "\$4" == "health" ]]; then
  printf '%s\n' "\${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}"
  exit 0
fi

if [[ "\$1" == "status" && "\${2:-}" == "-P" ]]; then
  cat <<'STATUS'
  pool: data
 state: \${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}
config:

        NAME                                                     STATE     READ WRITE CKSUM
        data                                                     \${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}       0     0     0
          mirror-0                                               \${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}       0     0     0
            ${by_id_dir}/ata-ST8000VN002-2ZM188_WPV3997N-part1   ONLINE       0     0     0
            ${by_id_dir}/ata-ST8000VN002-2ZM188_WPV37712-part1   ONLINE       0     0     0

errors: No known data errors
STATUS
  exit 0
fi

if [[ "\$1" == "status" ]]; then
  printf 'pool: %s\nstate: %s\n' "\$2" "\${RUNTIME_READINESS_ZPOOL_HEALTH:-ONLINE}"
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

cat >"$runtime_bin/lsblk" <<EOF
#!/usr/bin/env bash
set -euo pipefail

cat <<'JSON'
{
  "blockdevices": [
    { "path": "${system_disk_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "SK hynix SC401 SATA 256GB", "serial": "EI89QSTDS10309C9E", "fstype": null, "mountpoints": [] },
    { "path": "${system_part_actual}", "type": "part", "pkname": "${system_disk_actual}", "tran": null, "model": null, "serial": null, "fstype": "btrfs", "mountpoints": ["/", "/nix", "/persist"] },
    { "path": "${data_a_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "ST8000VN002-2ZM188", "serial": "WPV3997N", "fstype": null, "mountpoints": [] },
    { "path": "${data_a_part_actual}", "type": "part", "pkname": "${data_a_actual}", "tran": null, "model": null, "serial": null, "fstype": "zfs_member", "mountpoints": [] },
    { "path": "${data_b_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "ST8000VN002-2ZM188", "serial": "WPV37712", "fstype": null, "mountpoints": [] },
    { "path": "${data_b_part_actual}", "type": "part", "pkname": "${data_b_actual}", "tran": null, "model": null, "serial": null, "fstype": "zfs_member", "mountpoints": [] },
    { "path": "${retired_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "HGST HUS726T4TALA6L4", "serial": "V1JAKPNH", "fstype": null, "mountpoints": [] },
    { "path": "${usb_actual}", "type": "disk", "pkname": null, "tran": "usb", "model": "PSSD T7", "serial": "S7MLNS0Y711062N", "fstype": null, "mountpoints": [] },
    { "path": "${usb_part_actual}", "type": "part", "pkname": "${usb_actual}", "tran": null, "model": null, "serial": null, "fstype": "exfat", "mountpoints": [] }
  ]
}
JSON
EOF
chmod +x "$runtime_bin/lsblk"

cat >"$runtime_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift 3
if [[ "${1:-}" == "test" && "${2:-}" == "!" && "${3:-}" == "-x" && "${4:-}" == *"/emails/.internal-sync" ]]; then
  exit 0
fi
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

cat >"$runtime_bin/psql" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '100\t97\tt\n'
EOF
chmod +x "$runtime_bin/psql"

find "$runtime_bin" "$tmpdir" -maxdepth 1 -type f -perm -0100 -exec sed -i "1s|.*|#!${bash_path}|" {} +

manual_env=(
  "PATH=$runtime_bin:$tmpdir:$PATH"
  "RUNTIME_READINESS_REPO_ROOT=$TESTS_REPO_ROOT"
  "RUNTIME_HEALTH_SNAPSHOT_JSON_FILE=$snapshot_file"
  "STORAGE_DEVICE_DISCOVERY_DEV_DISK_ROOT=$dev_disk_root"
)

set +e
manual_output="$(
  env "${manual_env[@]}" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    bash scripts/check-runtime-readiness.sh 2>&1
)"
manual_status=$?
set -e
if (( manual_status != 0 )); then
  printf '%s\n' "$manual_output" >&2
fi
require_json_equal "$manual_status" "0" \
  "check-runtime-readiness.sh must pass by default when a mirrored pool is DEGRADED but mounted."
require_match <(printf '%s\n' "$manual_output") '^⚠️  zpool health DEGRADED:' \
  "check-runtime-readiness.sh must surface degraded ZFS health in operator output."
require_match <(printf '%s\n' "$manual_output") 'continuing because the mirrored pool is still available, but redundancy is lost' \
  "check-runtime-readiness.sh must explain why degraded mirrored storage still passes by default."
require_match <(printf '%s\n' "$manual_output") 'backup state: backup metadata is stale, but the removable target is absent' \
  "check-runtime-readiness.sh must warn when backups are stale but the removable target is absent."
require_match <(printf '%s\n' "$manual_output") '^✅ upload group users contains copyparty' \
  "check-runtime-readiness.sh must confirm the Copyparty upload bridge group membership."
require_match <(printf '%s\n' "$manual_output") '^✅ upload path writable:' \
  "check-runtime-readiness.sh must probe a managed personal upload root for write access."

monitor_json="$(
  env "${manual_env[@]}" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    bash scripts/check-runtime-readiness.sh --profile monitor --format json
)"
require_json_equal "$(jq -r '.profile' <<<"$monitor_json")" "monitor" \
  "check-runtime-readiness.sh JSON output must report the selected profile."
require_json_equal "$(jq -r '.backup.severity' <<<"$monitor_json")" "WARN" \
  "check-runtime-readiness.sh must downgrade stale removable-backup state to WARN when the target is absent."
require_json_equal "$(jq -r '.zfs.runtimeState' <<<"$monitor_json")" "degraded" \
  "check-runtime-readiness.sh monitor output must preserve the degraded runtime state."
require_json_equal "$(jq -r '[.smart[] | .label] | join(",")' <<<"$monitor_json")" "system,data1,data2,other1,other2" \
  "check-runtime-readiness.sh must classify discovered disks into system, live data-pool, and other groups."
require_json_equal "$(jq -r '.smart[] | select(.label == "data1") | .device' <<<"$monitor_json")" "${by_id_dir}/ata-ST8000VN002-2ZM188_WPV3997N" \
  "check-runtime-readiness.sh must normalize ZFS pool members to whole-disk by-id paths."
require_json_equal "$(jq -r --arg actual "${usb_actual}" '.smart[] | select(.actualDevice == $actual) | .smartctlArgs | join(" ")' <<<"$monitor_json")" "-d sntasmedia" \
  "check-runtime-readiness.sh must preserve discovered SMART transport arguments for USB backup disks."
require_json_equal "$(jq -r '.requiredPaths[] | select(.label == "copyparty-group-membership") | .severity' <<<"$monitor_json")" "OK" \
  "check-runtime-readiness.sh JSON output must record the Copyparty group bridge check."
require_json_equal "$(jq -r '.requiredPaths[] | select(.label == "copyparty-upload-root") | .severity' <<<"$monitor_json" | head -n 1)" "OK" \
  "check-runtime-readiness.sh JSON output must record successful Copyparty upload-root write probes."
require_json_equal "$(jq -r '.requiredPaths[] | select(.label == "mail-archive-ui-store-root") | .severity' <<<"$monitor_json")" "OK" \
  "check-runtime-readiness.sh JSON output must record the managed mail-archive store root."
require_json_equal "$(jq -r '.requiredPaths[] | select(.label == "mail-archive-hidden-sync-root") | .severity' <<<"$monitor_json")" "OK" \
  "check-runtime-readiness.sh JSON output must record a hidden mail-archive sync root probe."
require_json_equal "$(jq -r '.requiredPaths[] | select(.label == "mail-archive-visible-eml-readable") | .severity' <<<"$monitor_json")" "OK" \
  "check-runtime-readiness.sh JSON output must verify FileBrowser can read a visible mail archive .eml mirror file."
require_json_equal "$(jq -r '.requiredPaths[] | select(.label == "mail-archive-hidden-sync-not-traversable") | .severity' <<<"$monitor_json")" "OK" \
  "check-runtime-readiness.sh JSON output must verify FileBrowser cannot traverse the hidden mail archive sync root."
require_json_equal "$(jq -r '[.accessChecks.matrix[] | .accountId] | join(",")' <<<"$monitor_json")" "canary-files" \
  "check-runtime-readiness.sh JSON output must expose the runtime access canary matrix."
require_json_equal "$(jq -r '.accessChecks.matrix[] | select(.accountId == "canary-files") | [.expectedApps[] | .name] | join(",")' <<<"$monitor_json")" "uploads,files" \
  "check-runtime-readiness.sh JSON output must map the single canary to every applicable fixture app."
require_json_equal "$(jq -r '.accessChecks.localUnauth[] | select(.app == "uploads") | .severity' <<<"$monitor_json")" "OK" \
  "check-runtime-readiness.sh JSON output must record successful local unauthenticated upload-edge checks."
require_json_equal "$(jq -r '.accessChecks.localUnauth[] | select(.app == "files") | .finalUrl' <<<"$monitor_json")" "/api/auth/oidc/login?next=%2F" \
  "check-runtime-readiness.sh JSON output must record the local FileBrowser unauthenticated redirect."

set +e
deploy_output="$(
  env "${manual_env[@]}" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    bash scripts/check-runtime-readiness.sh --profile deploy 2>&1
)"
deploy_status=$?
set -e
require_json_equal "$deploy_status" "1" \
  "check-runtime-readiness.sh deploy profile must fail when the mirrored pool is DEGRADED."
require_match <(printf '%s\n' "$deploy_output") 'deploy profile requires ONLINE zpool health' \
  "check-runtime-readiness.sh deploy profile must explain the ONLINE-only guardrail."

printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${metadata_root}/timestamp.txt"
touch "${metadata_root}/app-state-roots.tsv" \
  "${metadata_root}/critical-paths.tsv" \
  "${metadata_root}/zpool-status.txt" \
  "${metadata_root}/zpool-list.txt" \
  "${metadata_root}/zfs-list.txt" \
  "${dumps_root}/postgresql.sql"

set +e
missing_bootstrap_output="$(
  env "${manual_env[@]}" \
    bash scripts/check-runtime-readiness.sh --profile manual --deep 2>&1
)"
missing_bootstrap_status=$?
set -e
require_json_equal "$missing_bootstrap_status" "1" \
  "check-runtime-readiness.sh deep mode must fail when canary bootstrap state is missing."
require_match <(printf '%s\n' "$missing_bootstrap_output") 'access canary bootstrap state missing:' \
  "check-runtime-readiness.sh deep mode must explain that canary bootstrap state is missing."

cat >"$bootstrap_state_file" <<'EOF'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "resetResults": [
    {
      "accountId": "canary-files",
      "severity": "CRITICAL",
      "detail": "page.goto: net::ERR_NAME_NOT_RESOLVED at https://idsydneybasiniotorg/ui/reset?token=bad"
    }
  ],
  "warmupResults": []
}
EOF
set +e
failed_bootstrap_output="$(
  env "${manual_env[@]}" \
    bash scripts/check-runtime-readiness.sh --profile manual --deep 2>&1
)"
failed_bootstrap_status=$?
set -e
require_json_equal "$failed_bootstrap_status" "1" \
  "check-runtime-readiness.sh deep mode must fail when bootstrap state records failed browser setup."
require_match <(printf '%s\n' "$failed_bootstrap_output") 'access canary bootstrap state contains failures:' \
  "check-runtime-readiness.sh deep mode must report failed canary bootstrap state before browser verification."

printf '%s\n' '{"timestamp":"2026-01-01T00:00:00Z"}' >"$bootstrap_state_file"
cat >"$helper_results_file" <<'EOF'
[
  {
    "scope": "authed",
    "app": "uploads",
    "canary": "canary-files",
    "severity": "OK",
    "detail": "landed on https://uploads.example.test/",
    "finalUrl": "https://uploads.example.test/",
    "httpCode": 200
  }
]
EOF

deep_json="$(
  env "${manual_env[@]}" \
    RUNTIME_ACCESS_BROWSER_CHECK_JSON_FILE="$helper_results_file" \
    bash scripts/check-runtime-readiness.sh --profile manual --deep --format json
)"
require_json_equal "$(jq -r '.overallSeverity' <<<"$deep_json")" "OK" \
  "check-runtime-readiness.sh deep checks must pass when database and backup fixtures are healthy."
require_json_equal "$(jq -r '[.deepChecks[] | select(.kind == "sqlite" and .severity == "OK")] | length' <<<"$deep_json")" "1" \
  "check-runtime-readiness.sh deep mode must run sqlite quick_check probes."
require_json_equal "$(jq -r '[.deepChecks[] | select(.kind == "postgresql" and .severity == "OK")] | length' <<<"$deep_json")" "2" \
  "check-runtime-readiness.sh deep mode must validate PostgreSQL connectivity and dump freshness."
require_json_equal "$(jq -r '[.deepChecks[] | select(.kind == "immich" and .severity == "OK")] | length' <<<"$deep_json")" "3" \
  "check-runtime-readiness.sh deep mode must validate Immich smart-search readiness."
require_json_equal "$(jq -r '.deepChecks[] | select(.kind == "immich" and .name == "smart-search-coverage") | .detail' <<<"$deep_json")" "97/100 active timeline assets have smart_search rows (97%)" \
  "check-runtime-readiness.sh deep mode must report Immich smart-search coverage."
require_json_equal "$(jq -r '[.accessChecks.authed[] | select(.severity == "OK")] | length' <<<"$deep_json")" "1" \
  "check-runtime-readiness.sh deep mode must include authenticated access-check results."

echo "✅ Runtime readiness tests passed."
