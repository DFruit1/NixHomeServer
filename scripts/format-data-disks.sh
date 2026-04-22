#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
source "$script_dir/lib-destructive-wrapper.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/format-data-disks.sh [--print-only]

Preview or recreate only the mirrored ZFS data-pool disks from
vars.zfsDataPool. The system SSD and manual cold-storage pools are out of
scope.

Examples:
  scripts/format-data-disks.sh --print-only
  scripts/format-data-disks.sh
EOF
}

print_only=false
case "${1:-}" in
  "")
    ;;
  --print-only)
    print_only=true
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

need nix jq readlink

if (( EUID != 0 )); then
  need sudo
fi

config_json="$(
  nix_json '{
    hostname = vars.hostname;
    poolName = vars.zfsDataPool.name;
    targetDiskIds = vars.zfsDataPoolDiskIds;
    mainDisk = vars.mainDisk;
    coldStorageDiskIds = map (pool: pool.disk) vars.coldStoragePools;
    expectedMemberCount = builtins.length (lib.flatten vars.zfsDataPool.mirrorPairs);
  }'
)"

hostname="$(jq -r '.hostname' <<<"$config_json")"
pool_name="$(jq -r '.poolName' <<<"$config_json")"
main_disk="$(jq -r '.mainDisk' <<<"$config_json")"
expected_member_count="$(jq -r '.expectedMemberCount' <<<"$config_json")"
mapfile -t target_disk_ids < <(jq -r '.targetDiskIds[]?' <<<"$config_json")
mapfile -t cold_storage_disk_ids < <(jq -r '.coldStorageDiskIds[]?' <<<"$config_json")

if (( ${#target_disk_ids[@]} == 0 )); then
  fail "vars.zfsDataPoolDiskIds is empty."
fi

declare -A seen_disk_ids=()
for disk_id in "${target_disk_ids[@]}"; do
  if [[ -n "${seen_disk_ids[$disk_id]:-}" ]]; then
    fail "vars.zfsDataPoolDiskIds contains a duplicate disk ID: ${disk_id}"
  fi
  seen_disk_ids["$disk_id"]=1
done

for disk_id in "${target_disk_ids[@]}"; do
  if [[ "$disk_id" == "$main_disk" ]]; then
    fail "vars.mainDisk must not appear in vars.zfsDataPoolDiskIds."
  fi
done

for cold_disk_id in "${cold_storage_disk_ids[@]}"; do
  for disk_id in "${target_disk_ids[@]}"; do
    if [[ "$disk_id" == "$cold_disk_id" ]]; then
      fail "vars.zfsDataPoolDiskIds must not include any vars.coldStoragePools disk."
    fi
  done
done

if [[ "${#target_disk_ids[@]}" -ne "$expected_member_count" ]]; then
  fail "vars.zfsDataPoolDiskIds count must match lib.flatten vars.zfsDataPool.mirrorPairs."
fi

disko_file="${repo_root}/disko.nix"
[[ -f "$disko_file" ]] || fail "Disko file is missing: ${disko_file}"
[[ "$disko_file" == "${repo_root}/disko.nix" ]] || fail "Data wrapper must use ./disko.nix."

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

run_cmd=("${sudo_cmd[@]}" nix run .#disko -- --mode zap_create_mount "$disko_file")
command_display="$(join_command "${run_cmd[@]}")"
target_disk_ids_display="$(join_by_space "${target_disk_ids[@]}")"
cold_storage_disk_ids_display="none"

if (( ${#cold_storage_disk_ids[@]} > 0 )); then
  cold_storage_disk_ids_display="$(join_by_space "${cold_storage_disk_ids[@]}")"
fi

echo "operation: format data disks"
echo "description: This script destroys and recreates only the mirrored data-pool disks for zpool ${pool_name}. Use it only for intentional mirrored-data-pool creation or recreation, and expect all existing pool member contents on those disks to be destroyed."
echo "disko file: ${disko_file}"
echo "target disk IDs: ${target_disk_ids_display}"
echo "target device paths under /dev/disk/by-id:"
print_device_paths "${target_disk_ids[@]}"
echo "current symlink resolution if the device exists:"
print_device_resolutions "${target_disk_ids[@]}"
echo "exact command that will run: ${command_display}"
echo "will not touch: system disk ${main_disk}; cold-storage disks ${cold_storage_disk_ids_display}"

if [[ "$print_only" == true ]]; then
  exit 0
fi

ensure_target_devices_exist "${target_disk_ids[@]}"

confirm_exact "Type hostname '${hostname}' to continue: " "$hostname"
confirm_exact "Type target disk IDs exactly as shown to continue: " "$target_disk_ids_display"
confirm_exact "Type 'DESTROY DATA DISKS' to continue: " "DESTROY DATA DISKS"

"${run_cmd[@]}"
