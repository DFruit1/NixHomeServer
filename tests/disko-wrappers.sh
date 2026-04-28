#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg readlink

echo "ℹ️ Checking destructive Disko wrapper previews…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

system_output="$(REPO_NIX_EVAL_CACHE_DIR="$tmpdir/nix-cache" ./scripts/format-system-disk.sh --print-only)"
data_output="$(REPO_NIX_EVAL_CACHE_DIR="$tmpdir/nix-cache" ./scripts/format-data-disks.sh --print-only)"

main_disk="$(nix_eval_var 'vars.mainDisk')"
pool_name="$(nix_eval_var 'vars.zfsDataPool.name')"
mapfile -t data_disk_ids < <(nix_eval_json 'vars.zfsDataPoolDiskIds' | jq -r '.[]')
mapfile -t cold_storage_disk_ids < <(nix_eval_json 'map (pool: pool.disk) vars.coldStoragePools' | jq -r '.[]?')

require_match <(printf '%s\n' "$system_output") '^operation: format system disk$' \
  "The system-disk wrapper preview must identify the operation."
require_match <(printf '%s\n' "$system_output") '^target disk IDs: '"$main_disk"'$' \
  "The system-disk wrapper preview must print vars.mainDisk."
require_match <(printf '%s\n' "$system_output") 'disko-system\.nix' \
  "The system-disk wrapper preview must reference disko-system.nix."
require_match <(printf '%s\n' "$system_output") '--mode zap_create_mount' \
  "The system-disk wrapper preview must show the destructive Disko mode."
require_match <(printf '%s\n' "$system_output") 'will not touch: mirrored data-pool disks' \
  "The system-disk wrapper preview must warn about the non-target data disks."
require_match <(printf '%s\n' "$system_output") 'cold-storage disks' \
  "The system-disk wrapper preview must warn about the non-target cold-storage disks."

require_match <(printf '%s\n' "$data_output") '^operation: format data disks$' \
  "The data-disk wrapper preview must identify the operation."
require_match <(printf '%s\n' "$data_output") 'disko\.nix' \
  "The data-disk wrapper preview must reference disko.nix."
require_match <(printf '%s\n' "$data_output") '--mode zap_create_mount' \
  "The data-disk wrapper preview must show the destructive Disko mode."
require_match <(printf '%s\n' "$data_output") "zpool ${pool_name}" \
  "The data-disk wrapper preview must print vars.zfsDataPool.name."
require_match <(printf '%s\n' "$data_output") 'will not touch: system disk' \
  "The data-disk wrapper preview must warn about the non-target system disk."
require_match <(printf '%s\n' "$data_output") 'cold-storage disks' \
  "The data-disk wrapper preview must warn about the non-target cold-storage disks."

for disk_id in "${data_disk_ids[@]}"; do
  require_match <(printf '%s\n' "$data_output") "$disk_id" \
    "The data-disk wrapper preview must print every vars.zfsDataPoolDiskIds member."
done

for cold_disk_id in "${cold_storage_disk_ids[@]}"; do
  require_match <(printf '%s\n' "$system_output") "$cold_disk_id" \
    "The system-disk wrapper preview must print configured cold-storage disk IDs."
  require_match <(printf '%s\n' "$data_output") "$cold_disk_id" \
    "The data-disk wrapper preview must print configured cold-storage disk IDs."
done

echo "ℹ️ Checking wrapper sources and documentation policy…"
require_fixed scripts/format-system-disk.sh 'vars.mainDisk' \
  "The system-disk wrapper source must reference vars.mainDisk."
require_fixed scripts/format-data-disks.sh 'vars.zfsDataPoolDiskIds' \
  "The data-disk wrapper source must reference vars.zfsDataPoolDiskIds."
forbid_match scripts/format-system-disk.sh 'disko-install\.nix' \
  "The system-disk wrapper must not reference the removed combined Disko path."
forbid_match scripts/format-data-disks.sh 'disko-install\.nix' \
  "The data-disk wrapper must not reference the removed combined Disko path."
forbid_match documentation/quickstart.md 'nix run github:nix-community/disko --' \
  "Quickstart must not present direct Disko invocation as the normal destructive path."
forbid_match documentation/restore-and-recovery.md 'nix run github:nix-community/disko --' \
  "Restore-and-recovery must not present direct Disko invocation as the normal destructive path."
forbid_match documentation/quickstart.md 'sgdisk --zap-all|wipefs -a' \
  "Quickstart must not recommend manual zap commands as the normal path."

echo "ℹ️ Checking shared Nix eval cache behavior…"
mkdir -p "$tmpdir/cache-bin" "$tmpdir/cache-dir"
counter_file="$tmpdir/nix-counter"

cat >"$tmpdir/cache-bin/nix" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '1' >>"$CACHE_TEST_COUNTER_FILE"

if [[ "$1" == "eval" && "$2" == "--json" ]]; then
  printf '{"value":1}\n'
  exit 0
fi

if [[ "$1" == "eval" && "$2" == "--raw" ]]; then
  printf 'cached-value'
  exit 0
fi

exit 1
EOF
chmod +x "$tmpdir/cache-bin/nix"

PATH="$tmpdir/cache-bin:$PATH" \
  CACHE_TEST_COUNTER_FILE="$counter_file" \
  bash -c '
    source scripts/lib-repo.sh
    init_repo_root
    ensure_default_nix_config
    nix_json "{ value = 1; }" >/dev/null
    nix_json "{ value = 1; }" >/dev/null
  '
require_json_equal "$(wc -c < "$counter_file" | tr -d " ")" "2" \
  "Without REPO_NIX_EVAL_CACHE_DIR, repeated nix_json calls must evaluate twice."

: >"$counter_file"
PATH="$tmpdir/cache-bin:$PATH" \
  CACHE_TEST_COUNTER_FILE="$counter_file" \
  REPO_NIX_EVAL_CACHE_DIR="$tmpdir/cache-dir" \
  bash -c '
    source scripts/lib-repo.sh
    init_repo_root
    ensure_default_nix_config
    nix_json "{ value = 1; }" >/dev/null
    nix_json "{ value = 1; }" >/dev/null
    nix_var "builtins.toString 1" >/dev/null
    nix_var "builtins.toString 1" >/dev/null
  '
require_json_equal "$(wc -c < "$counter_file" | tr -d " ")" "2" \
  "With REPO_NIX_EVAL_CACHE_DIR, repeated nix_json and nix_var calls must be cached per expression and mode."

echo "✅ Disko wrapper tests passed."
