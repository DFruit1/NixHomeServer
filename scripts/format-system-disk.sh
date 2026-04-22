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
Usage: scripts/format-system-disk.sh [--print-only]

Preview or recreate only the system SSD from vars.mainDisk using
disko-system.nix. The mirrored data pool and manual cold-storage pools are out
of scope.

Examples:
  scripts/format-system-disk.sh --print-only
  scripts/format-system-disk.sh
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
    mainDisk = vars.mainDisk;
    dataDiskIds = vars.zfsDataPoolDiskIds;
    coldStorageDiskIds = map (pool: pool.disk) vars.coldStoragePools;
  }'
)"

hostname="$(jq -r '.hostname' <<<"$config_json")"
main_disk="$(jq -r '.mainDisk' <<<"$config_json")"
mapfile -t data_disk_ids < <(jq -r '.dataDiskIds[]?' <<<"$config_json")
mapfile -t cold_storage_disk_ids < <(jq -r '.coldStorageDiskIds[]?' <<<"$config_json")

[[ -n "$main_disk" ]] || fail "vars.mainDisk is empty."

for disk_id in "${data_disk_ids[@]}"; do
  if [[ "$disk_id" == "$main_disk" ]]; then
    fail "vars.mainDisk must not appear in vars.zfsDataPoolDiskIds."
  fi
done

for disk_id in "${cold_storage_disk_ids[@]}"; do
  if [[ "$disk_id" == "$main_disk" ]]; then
    fail "vars.mainDisk must not match any vars.coldStoragePools disk."
  fi
done

disko_file="${repo_root}/disko-system.nix"
[[ -f "$disko_file" ]] || fail "Disko file is missing: ${disko_file}"
[[ "$disko_file" == "${repo_root}/disko-system.nix" ]] || fail "System wrapper must use ./disko-system.nix."

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

run_cmd=("${sudo_cmd[@]}" nix run .#disko -- --mode zap_create_mount "$disko_file")
command_display="$(join_command "${run_cmd[@]}")"
target_disk_ids=("$main_disk")
target_disk_ids_display="$(join_by_space "${target_disk_ids[@]}")"
data_disk_ids_display="none"
cold_storage_disk_ids_display="none"

if (( ${#data_disk_ids[@]} > 0 )); then
  data_disk_ids_display="$(join_by_space "${data_disk_ids[@]}")"
fi

if (( ${#cold_storage_disk_ids[@]} > 0 )); then
  cold_storage_disk_ids_display="$(join_by_space "${cold_storage_disk_ids[@]}")"
fi

echo "operation: format system disk"
echo "description: This script destroys and recreates only the Btrfs system SSD layout for blank-machine system-disk provisioning or intentional SSD reinitialization."
echo "disko file: ${disko_file}"
echo "target disk IDs: ${target_disk_ids_display}"
echo "target device paths under /dev/disk/by-id:"
print_device_paths "${target_disk_ids[@]}"
echo "current symlink resolution if the device exists:"
print_device_resolutions "${target_disk_ids[@]}"
echo "exact command that will run: ${command_display}"
echo "will not touch: mirrored data-pool disks ${data_disk_ids_display}; cold-storage disks ${cold_storage_disk_ids_display}"

if [[ "$print_only" == true ]]; then
  exit 0
fi

ensure_target_devices_exist "${target_disk_ids[@]}"

confirm_exact "Type hostname '${hostname}' to continue: " "$hostname"
confirm_exact "Type target disk IDs exactly as shown to continue: " "$target_disk_ids_display"
confirm_exact "Type 'DESTROY SYSTEM DISK' to continue: " "DESTROY SYSTEM DISK"

"${run_cmd[@]}"
