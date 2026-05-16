#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools bash jq mktemp sqlite3

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

stub_bin="$tmpdir/bin"
bash_path="$(command -v bash)"
mkdir -p "$stub_bin"

cat >"$stub_bin/clamdscan" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${STUB_CLAM_MODE:-clean}" in
  clean)
    echo "$*: OK"
    exit 0
    ;;
  infected)
    echo "$*: Eicar-Test-Signature FOUND"
    exit 1
    ;;
  encrypted)
    echo "$*: Heuristics.Encrypted.PDF FOUND"
    exit 1
    ;;
  timeout)
    sleep 5
    ;;
  error)
    echo "$*: Can't connect to clamd"
    exit 2
    ;;
esac
EOF
sed -i "1s|.*|#!$bash_path|" "$stub_bin/clamdscan"
chmod +x "$stub_bin/clamdscan"

cat >"$stub_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${STUB_VT_CALLS:?}"
case "${STUB_VT_MODE:-clean}" in
  clean)
    printf '{"data":{"attributes":{"last_analysis_stats":{"malicious":0,"suspicious":0}}}}\n200'
    ;;
  malicious)
    printf '{"data":{"attributes":{"last_analysis_stats":{"malicious":1,"suspicious":0}}}}\n200'
    ;;
  unknown)
    printf '{"error":{"code":"NotFoundError"}}\n404'
    ;;
  network)
    echo "network down" >&2
    exit 7
    ;;
esac
EOF
sed -i "1s|.*|#!$bash_path|" "$stub_bin/curl"
chmod +x "$stub_bin/curl"

cat >"$stub_bin/kiwix-manage" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${STUB_KIWIX_MODE:-valid}" == "valid" ]]; then
  exit 0
fi
exit 1
EOF
sed -i "1s|.*|#!$bash_path|" "$stub_bin/kiwix-manage"
chmod +x "$stub_bin/kiwix-manage"

cat >"$stub_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"${STUB_SYSTEMCTL_CALLS:?}"
EOF
sed -i "1s|.*|#!$bash_path|" "$stub_bin/systemctl"
chmod +x "$stub_bin/systemctl"

run_case() {
  local name="$1" extension="$2" uploader="$3"
  shift 3

  local root="$tmpdir/$name"
  local staging="$root/staging"
  local users="$root/users"
  local quarantine="$root/quarantine"
  local kiwix="$root/kiwix"
  local queue="$root/run/queue"
  local state="$root/state/state.sqlite"
  local vt_secret="$root/vt.key"
  local vt_calls="$root/vt.calls"
  local systemctl_calls="$root/systemctl.calls"
  local file="$staging/$uploader/sample.$extension"

  mkdir -p "$staging/$uploader" "$users/$uploader/files" "$quarantine" "$kiwix" "$queue" "$(dirname "$state")"
  printf 'payload' >"$file"
  printf 'vt-key' >"$vt_secret"
  : >"$vt_calls"
  : >"$systemctl_calls"

  PATH="$stub_bin:$PATH" \
  UPLOAD_STAGING_ROOT="$staging" \
  UPLOAD_USERS_ROOT="$users" \
  UPLOAD_QUARANTINE_ROOT="$quarantine" \
  UPLOAD_KIWIX_LIBRARY_ROOT="$kiwix" \
  UPLOAD_PROCESSOR_QUEUE_DIR="$queue" \
  UPLOAD_PROCESSOR_STATE_DB="$state" \
  UPLOAD_VIRUSTOTAL_API_KEY_FILE="$vt_secret" \
  UPLOAD_SCAN_SETTLE_SECONDS=0 \
  UPLOAD_CLAMAV_TIMEOUT_SECONDS=1 \
  UPLOAD_VIRUSTOTAL_TIMEOUT_SECONDS=1 \
  UPLOAD_ZIM_PROMOTION_USERS="admin" \
  UPLOAD_QUARANTINE_OWNER="$(id -un)" \
  UPLOAD_QUARANTINE_GROUP="$(id -gn)" \
  UPLOAD_FINAL_OWNER="$(id -un)" \
  UPLOAD_FINAL_GROUP="$(id -gn)" \
  UPLOAD_KIWIX_OWNER="$(id -un)" \
  UPLOAD_KIWIX_GROUP="$(id -gn)" \
  STUB_VT_CALLS="$vt_calls" \
  STUB_SYSTEMCTL_CALLS="$systemctl_calls" \
  "$@" \
  bash scripts/helpers/upload-processor.sh file "$file" "$uploader" "/$uploader/sample.$extension"

  printf '%s\n' "$root"
}

assert_exists() {
  [[ -e "$1" ]] || {
    echo "❌ Missing expected path: $1"
    local root="${1%%/users/*}"
    root="${root%%/quarantine/*}"
    root="${root%%/kiwix/*}"
    if [[ -d "$root" ]]; then
      find "$root" -maxdepth 5 -print | sort >&2
      find "$root" -name state.sqlite -exec sqlite3 '{}' 'select path,state,last_error,destination_path,quarantine_path from uploads;' \; >&2 || true
    fi
    exit 1
  }
}

assert_missing() {
  [[ ! -e "$1" ]] || {
    echo "❌ Unexpected path exists: $1"
    exit 1
  }
}

root="$(run_case low_clean pdf alice env STUB_CLAM_MODE=clean STUB_VT_MODE=clean)"
assert_exists "$root/users/alice/files/sample.pdf"
[[ ! -s "$root/vt.calls" ]] || { echo "❌ Low-risk clean file must not call VirusTotal."; exit 1; }

root="$(run_case low_infected pdf alice env STUB_CLAM_MODE=infected STUB_VT_MODE=clean)"
assert_exists "$(find "$root/quarantine/clamav-infected/alice" -type f ! -name '*.json' | head -n1)"

root="$(run_case low_timeout pdf alice env STUB_CLAM_MODE=timeout STUB_VT_MODE=clean)"
assert_exists "$root/staging/alice/sample.pdf"

root="$(run_case high_infected exe alice env STUB_CLAM_MODE=infected STUB_VT_MODE=clean)"
assert_exists "$(find "$root/quarantine/clamav-infected/alice" -type f ! -name '*.json' | head -n1)"
[[ ! -s "$root/vt.calls" ]] || { echo "❌ High-risk ClamAV-infected file must not call VirusTotal."; exit 1; }

root="$(run_case high_clean exe alice env STUB_CLAM_MODE=clean STUB_VT_MODE=clean)"
assert_exists "$root/users/alice/files/sample.exe"
require_match "$root/vt.calls" '/api/v3/files/' "High-risk clean file must perform VirusTotal hash lookup."

root="$(run_case high_malicious exe alice env STUB_CLAM_MODE=clean STUB_VT_MODE=malicious)"
assert_exists "$(find "$root/quarantine/virustotal-flagged/alice" -type f ! -name '*.json' | head -n1)"

root="$(run_case high_unknown exe alice env STUB_CLAM_MODE=clean STUB_VT_MODE=unknown)"
assert_exists "$(find "$root/quarantine/vt-unknown-manual-review/alice" -type f ! -name '*.json' | head -n1)"

root="$(run_case high_network exe alice env STUB_CLAM_MODE=clean STUB_VT_MODE=network)"
assert_exists "$root/staging/alice/sample.exe"

root="$(run_case encrypted pdf alice env STUB_CLAM_MODE=encrypted STUB_VT_MODE=clean)"
assert_exists "$(find "$root/quarantine/clamav-encrypted/alice" -type f ! -name '*.json' | head -n1)"

root="$(run_case zim_non_admin zim alice env STUB_CLAM_MODE=clean STUB_VT_MODE=clean STUB_KIWIX_MODE=valid)"
assert_exists "$(find "$root/quarantine/zim-admin-required/alice" -type f ! -name '*.json' | head -n1)"

root="$(run_case zim_admin_valid zim admin env STUB_CLAM_MODE=clean STUB_VT_MODE=clean STUB_KIWIX_MODE=valid)"
assert_exists "$root/kiwix/sample.zim"
require_match "$root/systemctl.calls" 'kiwix-library-sync\.service' "Valid admin ZIM promotion must trigger Kiwix sync."

root="$(run_case zim_admin_invalid zim admin env STUB_CLAM_MODE=clean STUB_VT_MODE=clean STUB_KIWIX_MODE=invalid)"
assert_exists "$(find "$root/quarantine/zim-invalid/admin" -type f ! -name '*.json' | head -n1)"

root="$(run_case traversal exe alice env STUB_CLAM_MODE=clean STUB_VT_MODE=clean)"
mkdir -p "$root/outside"
printf 'payload' >"$root/outside/escape.exe"
PATH="$stub_bin:$PATH" \
UPLOAD_STAGING_ROOT="$root/staging" \
UPLOAD_USERS_ROOT="$root/users" \
UPLOAD_QUARANTINE_ROOT="$root/quarantine" \
UPLOAD_KIWIX_LIBRARY_ROOT="$root/kiwix" \
UPLOAD_PROCESSOR_QUEUE_DIR="$root/run/queue" \
UPLOAD_PROCESSOR_STATE_DB="$root/state/state.sqlite" \
UPLOAD_VIRUSTOTAL_API_KEY_FILE="$root/vt.key" \
UPLOAD_SCAN_SETTLE_SECONDS=0 \
UPLOAD_QUARANTINE_OWNER="$(id -un)" \
UPLOAD_QUARANTINE_GROUP="$(id -gn)" \
UPLOAD_FINAL_OWNER="$(id -un)" \
UPLOAD_FINAL_GROUP="$(id -gn)" \
UPLOAD_KIWIX_OWNER="$(id -un)" \
UPLOAD_KIWIX_GROUP="$(id -gn)" \
STUB_VT_CALLS="$root/vt.calls" \
STUB_SYSTEMCTL_CALLS="$root/systemctl.calls" \
bash scripts/helpers/upload-processor.sh file "$root/staging/alice/../../outside/escape.exe" alice "/../escape.exe"
assert_exists "$root/outside/escape.exe"
assert_missing "$root/users/alice/files/escape.exe"

root="$tmpdir/internal_hist"
mkdir -p "$root/staging/alice/.hist" "$root/users/alice/files" "$root/quarantine" "$root/kiwix" "$root/run/queue" "$root/state"
printf 'copyparty-state' >"$root/staging/alice/.hist/up2k.db"
printf 'vt-key' >"$root/vt.key"
: >"$root/vt.calls"
: >"$root/systemctl.calls"
PATH="$stub_bin:$PATH" \
UPLOAD_STAGING_ROOT="$root/staging" \
UPLOAD_USERS_ROOT="$root/users" \
UPLOAD_QUARANTINE_ROOT="$root/quarantine" \
UPLOAD_KIWIX_LIBRARY_ROOT="$root/kiwix" \
UPLOAD_PROCESSOR_QUEUE_DIR="$root/run/queue" \
UPLOAD_PROCESSOR_STATE_DB="$root/state/state.sqlite" \
UPLOAD_VIRUSTOTAL_API_KEY_FILE="$root/vt.key" \
UPLOAD_SCAN_SETTLE_SECONDS=0 \
UPLOAD_QUARANTINE_OWNER="$(id -un)" \
UPLOAD_QUARANTINE_GROUP="$(id -gn)" \
UPLOAD_FINAL_OWNER="$(id -un)" \
UPLOAD_FINAL_GROUP="$(id -gn)" \
UPLOAD_KIWIX_OWNER="$(id -un)" \
UPLOAD_KIWIX_GROUP="$(id -gn)" \
STUB_VT_CALLS="$root/vt.calls" \
STUB_SYSTEMCTL_CALLS="$root/systemctl.calls" \
bash scripts/helpers/upload-processor.sh file "$root/staging/alice/.hist/up2k.db" alice "/alice/.hist/up2k.db"
assert_exists "$root/staging/alice/.hist/up2k.db"
assert_missing "$root/quarantine/vt-unknown-manual-review/alice"
[[ ! -s "$root/vt.calls" ]] || { echo "❌ Internal Copyparty state must not call VirusTotal."; exit 1; }

echo "✅ Upload processor tests passed."
