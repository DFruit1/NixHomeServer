#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp rg

echo "ℹ️ Checking storage health helper fixture behavior…"
fixture_dir="$TESTS_REPO_ROOT/scripts/tests/fixtures/storage-health"
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
    scripts/helpers/storage-health-common.sh --mode warn \
      clean=/dev/disk/by-id/clean \
      aging=/dev/disk/by-id/aging
)"
require_match <(printf '%s\n' "$warn_output") '^OK[[:space:]]+clean[[:space:]]+/dev/disk/by-id/clean$' \
  "Storage health helper must report clean disks as OK."
require_match <(printf '%s\n' "$warn_output") '^WARN[[:space:]]+aging[[:space:]]+/dev/disk/by-id/aging$' \
  "Storage health helper must warn on non-critical degradation counters."
require_match <(printf '%s\n' "$warn_output") 'Reallocated_Sector_Ct=8' \
  "Storage health helper must surface warning counters in operator output."

set +e
critical_output="$(
  PATH="$tmpdir:$PATH" \
    STORAGE_HEALTH_FIXTURE_DIR="$fixture_dir" \
    scripts/helpers/storage-health-common.sh --mode strict \
      critical=/dev/disk/by-id/critical 2>&1
)"
critical_status=$?
set -e
require_json_equal "$critical_status" "1" \
  "Storage health helper strict mode must fail on critical degradation counters."
require_match <(printf '%s\n' "$critical_output") '^CRITICAL[[:space:]]+critical[[:space:]]+/dev/disk/by-id/critical$' \
  "Storage health helper must report critical disks clearly."
require_match <(printf '%s\n' "$critical_output") 'Offline_Uncorrectable=6' \
  "Storage health helper must surface critical media errors in operator output."

transport_output="$(
  PATH="$tmpdir:$PATH" \
    STORAGE_HEALTH_FIXTURE_DIR="$fixture_dir" \
    STORAGE_HEALTH_JOURNAL_FIXTURE="$fixture_dir/transport.journal" \
    scripts/helpers/storage-health-common.sh --mode warn \
      transport=/dev/disk/by-id/transport
)"
require_match <(printf '%s\n' "$transport_output") '^CRITICAL[[:space:]]+transport[[:space:]]+/dev/disk/by-id/transport$' \
  "Storage health helper must escalate recent transport failures."
require_match <(printf '%s\n' "$transport_output") 'recent kernel transport errors' \
  "Storage health helper must explain transport-related critical results."

reported_uncorrect_output="$(
  PATH="$tmpdir:$PATH" \
    STORAGE_HEALTH_FIXTURE_DIR="$fixture_dir" \
    scripts/helpers/storage-health-common.sh --mode warn \
      lone=/dev/disk/by-id/reported-uncorrect-alone
)"
require_match <(printf '%s\n' "$reported_uncorrect_output") '^OK[[:space:]]+lone[[:space:]]+/dev/disk/by-id/reported-uncorrect-alone$' \
  "A lone historical Reported_Uncorrect=1 must not warn by itself."

echo "✅ Storage health helper tests passed."
