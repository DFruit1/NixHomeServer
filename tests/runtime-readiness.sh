#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg mktemp

echo "ℹ️ Checking runtime-readiness topology handling…"
require_fixed scripts/runtime-readiness.sh 'source "$script_dir/lib-repo.sh"' \
  "runtime-readiness.sh must source the shared repo helper."
require_fixed scripts/runtime-readiness.sh 'source "$repo_root/scripts/lib-storage-health.sh"' \
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

echo "✅ Runtime readiness tests passed."
