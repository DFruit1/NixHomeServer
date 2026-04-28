#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg mktemp

echo "ℹ️ Checking runtime-readiness topology handling…"
require_fixed scripts/runtime-readiness.sh 'source "$script_dir/lib-repo.sh"' \
  "runtime-readiness.sh must source the shared repo helper."
require_fixed scripts/runtime-readiness.sh 'source "$script_dir/lib-storage-health.sh"' \
  "runtime-readiness.sh must source the shared SMART helper."
require_fixed scripts/runtime-readiness.sh 'echo "== SMART =="' \
  "runtime-readiness.sh must report a dedicated SMART section."
require_fixed scripts/runtime-readiness.sh 'vars.zfsDataPool.datasets' \
  "runtime-readiness.sh must derive dataset mount checks from vars.zfsDataPool.datasets."
require_fixed scripts/runtime-readiness.sh 'vars.monitoredStorageDiskIds' \
  "runtime-readiness.sh must derive SMART devices from vars.monitoredStorageDiskIds."
require_fixed scripts/runtime-readiness.sh 'copyparty.service' \
  "runtime-readiness.sh must require the Copyparty unit."
require_fixed scripts/runtime-readiness.sh 'check_http "http://127.0.0.1:3923/" 200 302 401 403' \
  "runtime-readiness.sh must probe the direct Copyparty upstream."
require_fixed scripts/runtime-readiness.sh 'check_mount "$data_pool_mount" "zfs"' \
  "runtime-readiness.sh must verify the ZFS data pool mount."
require_fixed scripts/runtime-readiness.sh 'echo "== ZFS =="' \
  "runtime-readiness.sh must report a dedicated ZFS section."
require_fixed scripts/runtime-readiness.sh '--require-online-zpool' \
  "runtime-readiness.sh must expose a strict ZFS health mode for deploy gates."
require_fixed scripts/runtime-readiness.sh 'cfg.repo.impermanence.inventory.persistenceDirectories' \
  "runtime-readiness.sh must derive persistence checks from the impermanence inventory."
require_fixed scripts/runtime-readiness.sh 'echo "== Persistence =="' \
  "runtime-readiness.sh must report a dedicated persistence section when impermanence is enabled."
forbid_match scripts/runtime-readiness.sh 'mnt-backup|backup_mount_point|backup_disk_enabled' \
  "runtime-readiness.sh must not retain the removed local backup-mount workflow."

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

echo "ℹ️ Checking degraded ZFS readiness behavior…"
runtime_root="${tmpdir}/runtime"
runtime_bin="${runtime_root}/bin"
runtime_mount_root="${runtime_root}/mounts"
mkdir -p "$runtime_bin" \
  "${runtime_mount_root}/data/media/documents/archive/.hist" \
  "${runtime_mount_root}/data/users" \
  "${runtime_mount_root}/data/shared"

cat >"$runtime_bin/nix" <<EOF
#!/usr/bin/env bash
set -euo pipefail

expr="\${!#}"
mount_root="${runtime_mount_root}"
query="\$(printf '%s\n' "\$expr" | awk 'NF { line = \$0 } END { sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line); print line }')"

case "\$query" in
  vars.hostname)
    printf 'server\n'
    ;;
  vars.domain)
    printf 'example.test\n'
    ;;
  vars.nbIP)
    printf '100.64.0.10\n'
    ;;
  vars.serverLanIP)
    printf '192.168.8.12\n'
    ;;
  vars.dnsMode)
    printf 'split-horizon\n'
    ;;
  vars.filesDomain)
    printf 'files.example.test\n'
    ;;
  vars.mediaRoot)
    printf '%s/data/media\n' "\$mount_root"
    ;;
  vars.lanDnsDomain)
    printf 'home.arpa\n'
    ;;
  vars.kiwixDomain)
    printf 'wiki.example.test\n'
    ;;
  vars.photosDomain)
    printf 'photos.example.test\n'
    ;;
  vars.sharePhotosDomain)
    printf 'sharephotos.example.test\n'
    ;;
  vars.audiobooksDomain)
    printf 'audiobooks.example.test\n'
    ;;
  vars.kavitaDomain)
    printf 'books.example.test\n'
    ;;
  vars.jellyfinDomain)
    printf 'videos.example.test\n'
    ;;
  vars.kanidmDomain)
    printf 'id.example.test\n'
    ;;
  vars.cloudflareTunnelName)
    printf 'metro\n'
    ;;
  'vars.zfsDataPool.name')
    printf 'data\n'
    ;;
  'vars.zfsDataPool.mountPoint')
    printf '%s/data\n' "\$mount_root"
    ;;
  'if cfg.repo.impermanence.enablePersistence then "true" else "false"')
    printf 'false\n'
    ;;
  'toString (builtins.length vars.monitoredDataDiskIds)')
    printf '2\n'
    ;;
  'map (dataset: "\${vars.zfsDataPool.mountPoint}/\${dataset}") vars.zfsDataPool.datasets')
    printf '["%s/data/media","%s/data/users","%s/data/shared"]\n' "\$mount_root" "\$mount_root" "\$mount_root"
    ;;
  'map (diskId: "/dev/disk/by-id/\${diskId}") vars.monitoredStorageDiskIds')
    printf '["/dev/disk/by-id/disk1","/dev/disk/by-id/disk2"]\n'
    ;;
  'map (pool: pool.name) vars.coldStoragePools')
    printf '[]\n'
    ;;
  'cfg.repo.impermanence.inventory.persistenceDirectories')
    printf '[]\n'
    ;;
  'cfg.repo.impermanence.inventory.persistenceFiles')
    printf '[]\n'
    ;;
  *)
    printf 'unexpected nix expr: %s\n' "\$query" >&2
    exit 1
    ;;
esac
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
  192.168.8.12)
    printf '12.8.168.192.in-addr.arpa domain name pointer server.home.arpa.\n'
    ;;
  *)
    printf '%s has address 192.168.8.12\n' "$name"
    ;;
esac
EOF
chmod +x "$runtime_bin/host"

cat >"$runtime_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
chmod +x "$runtime_bin/systemctl"

cat >"$runtime_bin/findmnt" <<EOF
#!/usr/bin/env bash
set -euo pipefail

target="\${!#}"
case "\$target" in
  "${runtime_mount_root}/data"|\
  "${runtime_mount_root}/data/media"|\
  "${runtime_mount_root}/data/users"|\
  "${runtime_mount_root}/data/shared")
    printf 'zfs\n'
    ;;
  *)
    exit 1
    ;;
esac
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
  printf 'data\t%s/data\n' "${runtime_mount_root}"
  printf 'data/media\t%s/data/media\n' "${runtime_mount_root}"
  printf 'data/users\t%s/data/users\n' "${runtime_mount_root}"
  printf 'data/shared\t%s/data/shared\n' "${runtime_mount_root}"
  exit 0
fi

exit 1
EOF
chmod +x "$runtime_bin/zfs"

cat >"$runtime_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
shift 2
exec "$@"
EOF
chmod +x "$runtime_bin/runuser"

cat >"$runtime_bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-u" ]]; then
  shift 2
fi

exec "$@"
EOF
chmod +x "$runtime_bin/sudo"

set +e
degraded_output="$(
  PATH="$runtime_bin:$PATH" \
    RUNTIME_READINESS_REPO_ROOT="$TESTS_REPO_ROOT" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    scripts/runtime-readiness.sh 2>&1
)"
degraded_status=$?
set -e
require_json_equal "$degraded_status" "0" \
  "runtime-readiness.sh must pass by default when a mirrored pool is DEGRADED but mounted."
require_match <(printf '%s\n' "$degraded_output") '^⚠️  zpool health DEGRADED:' \
  "runtime-readiness.sh must surface degraded ZFS health in operator output."
require_match <(printf '%s\n' "$degraded_output") 'continuing because the mirrored pool is still available, but redundancy is lost' \
  "runtime-readiness.sh must explain why degraded mirrored storage still passes by default."

set +e
strict_output="$(
  PATH="$runtime_bin:$PATH" \
    RUNTIME_READINESS_REPO_ROOT="$TESTS_REPO_ROOT" \
    RUNTIME_READINESS_ZPOOL_HEALTH=DEGRADED \
    scripts/runtime-readiness.sh --require-online-zpool 2>&1
)"
strict_status=$?
set -e
require_json_equal "$strict_status" "1" \
  "runtime-readiness.sh strict mode must fail when the mirrored pool is DEGRADED."
require_match <(printf '%s\n' "$strict_output") 'strict mode requires ONLINE zpool health' \
  "runtime-readiness.sh strict mode must explain the ONLINE-only guardrail."

echo "✅ Runtime readiness tests passed."
