#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

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

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

fail() {
  echo "❌ $1" >&2
  exit 1
}

nix_json() {
  local expr="$1"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      lib = flake.inputs.nixpkgs.lib;
      vars = import ${repo_root}/vars.nix { inherit lib; };
    in
      ${expr}
  "
}

join_by_space() {
  local first=1
  local item

  for item in "$@"; do
    if (( first )); then
      printf '%s' "$item"
      first=0
    else
      printf ' %s' "$item"
    fi
  done
}

join_command() {
  local rendered
  printf -v rendered '%q ' "$@"
  printf '%s\n' "${rendered% }"
}

print_device_paths() {
  local disk_id
  for disk_id in "$@"; do
    echo "  - /dev/disk/by-id/${disk_id}"
  done
}

print_device_resolutions() {
  local disk_id device resolved
  for disk_id in "$@"; do
    device="/dev/disk/by-id/${disk_id}"
    if [[ -e "$device" ]]; then
      resolved="$(readlink -f -- "$device" 2>/dev/null || true)"
      if [[ -n "$resolved" ]]; then
        echo "  - ${device} -> ${resolved}"
      else
        echo "  - ${device} -> present but resolution failed"
      fi
    else
      echo "  - ${device} -> missing"
    fi
  done
}

ensure_target_devices_exist() {
  local disk_id device missing=0
  for disk_id in "$@"; do
    device="/dev/disk/by-id/${disk_id}"
    if [[ ! -e "$device" ]]; then
      echo "❌ Target device path is missing: ${device}" >&2
      missing=1
    fi
  done

  if (( missing )); then
    exit 1
  fi
}

confirm_exact() {
  local prompt="$1"
  local expected="$2"
  local actual

  if [[ ! -e /dev/tty ]]; then
    fail "Interactive confirmation requires /dev/tty. Use --print-only for a non-destructive preview."
  fi

  if ! read -r -p "${prompt}" actual < /dev/tty; then
    fail "Failed to read confirmation."
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "❌ Confirmation mismatch." >&2
    echo "   Expected: ${expected}" >&2
    echo "   Actual:   ${actual}" >&2
    exit 1
  fi
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
