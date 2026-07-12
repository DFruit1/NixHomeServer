#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

dev_disk_root="${STORAGE_DEVICE_DISCOVERY_DEV_DISK_ROOT:-/dev/disk}"
by_id_dir="${dev_disk_root}/by-id"
lsblk_bin="${STORAGE_DEVICE_DISCOVERY_LSBLK_BIN:-lsblk}"
smartctl_bin="${STORAGE_DEVICE_DISCOVERY_SMARTCTL_BIN:-smartctl}"
zpool_bin="${STORAGE_DEVICE_DISCOVERY_ZPOOL_BIN:-zpool}"
readlink_bin="${STORAGE_DEVICE_DISCOVERY_READLINK_BIN:-readlink}"

usage() {
  cat <<'EOF'
Usage: scripts/discover-storage-devices.sh [--format json|text] [--config-json-file <path>]

Discover the current system disk, live ZFS data-pool members when the selected
storage profile uses ZFS, and all other attached non-system disks for SMART
monitoring.
EOF
}

format="json"
config_json_file="${STORAGE_DEVICE_DISCOVERY_CONFIG_JSON_FILE:-}"

while (($# > 0)); do
  case "$1" in
    --format)
      format="${2:-}"
      shift 2
      ;;
    --config-json-file)
      config_json_file="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$format" in
  json|text)
    ;;
  *)
    echo "❌ --format must be json or text." >&2
    exit 1
    ;;
esac

for required_command in jq "$lsblk_bin" "$smartctl_bin" "$readlink_bin"; do
  command -v "$required_command" >/dev/null 2>&1 || {
    echo "❌ Required command not found: $required_command" >&2
    exit 1
  }
done

declare -A smartctl_args_by_device=()
declare -a smartctl_scan_devices=()
declare -A seen_smart_device=()
declare -A zfs_data_actual_devices=()

lsblk_json=""
inventory_json=""

trim_whitespace() {
  sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

load_discovery_config_json() {
  if [[ -n "$config_json_file" ]]; then
    cat "$config_json_file"
    return 0
  fi

  # Interactive repository use may evaluate vars.nix. Runtime services always
  # provide a pre-rendered JSON file and therefore have no repository or Nix
  # dependency.
  source "$script_dir/helpers/repo-common.sh"
  init_repo_root "STORAGE_DEVICE_DISCOVERY_REPO_ROOT"
  cd_repo_root
  ensure_default_nix_config

  nix_json '{
    storageProfile = vars.storageProfile;
    systemDisk = {
      diskId = vars.mainDisk;
      device = "/dev/disk/by-id/${vars.mainDisk}";
    };
    dataPool = {
      name = vars.zfsDataPool.name;
      mountPoint = vars.zfsDataPool.mountPoint;
      datasetMounts = map (dataset: "${vars.zfsDataPool.mountPoint}/${dataset}") vars.zfsDataPool.datasets;
    };
  }'
}

load_lsblk_json() {
  if [[ -z "$lsblk_json" ]]; then
    lsblk_json="$("$lsblk_bin" -J -p -o PATH,TYPE,PKNAME,TRAN,MODEL,SERIAL,FSTYPE,MOUNTPOINTS)"
  fi
  printf '%s\n' "$lsblk_json"
}

load_inventory_json() {
  if [[ -z "$inventory_json" ]]; then
    load_lsblk_json >/dev/null
    inventory_json="$(
      jq '
        [
          .blockdevices[]
          | {
              path,
              type,
              pkname: (.pkname // ""),
              tran: (.tran // ""),
              model: (.model // ""),
              serial: (.serial // ""),
              fstype: (.fstype // ""),
              mountpoints: ((.mountpoints // []) | map(select(type == "string" and . != "")))
            }
        ]
      ' <<<"$lsblk_json"
    )"
  fi
  printf '%s\n' "$inventory_json"
}

resolve_path_or_empty() {
  local path="$1"
  "$readlink_bin" -f "$path" 2>/dev/null || true
}

actual_disk_for_path() {
  local path="$1"
  local resolved
  local whole_disk_link=""

  if [[ "$(basename "$path")" =~ ^(.+)-part[0-9]+$ ]]; then
    whole_disk_link="$(dirname "$path")/${BASH_REMATCH[1]}"
    resolved="$(resolve_path_or_empty "$whole_disk_link")"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  resolved="$(resolve_path_or_empty "$path")"
  if [[ -z "$resolved" ]]; then
    resolved="$path"
  fi

  printf '%s\n' "$resolved"
}

whole_disk_by_id_candidates_for_actual() {
  local actual_path="$1"
  local link
  local target

  shopt -s nullglob
  for link in "$by_id_dir"/*; do
    [[ -L "$link" ]] || continue
    target="$(resolve_path_or_empty "$link")"
    if [[ "$target" == "$actual_path" && ! "$(basename "$link")" =~ -part[0-9]+$ ]]; then
      printf '%s\n' "$link"
    fi
  done
  shopt -u nullglob
}

preferred_whole_disk_by_id_for_actual() {
  local actual_path="$1"
  local candidate
  local fallback=""

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$(basename "$candidate")" != wwn-* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if [[ -z "$fallback" ]]; then
      fallback="$candidate"
    fi
  done < <(whole_disk_by_id_candidates_for_actual "$actual_path")

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  return 1
}

smartctl_scan_load() {
  local line device args

  while IFS= read -r line; do
    if [[ "$line" =~ ^(/[^[:space:]]+)([[:space:]]+([^#]+))?[[:space:]]*# ]]; then
      device="${BASH_REMATCH[1]}"
      args="$(printf '%s\n' "${BASH_REMATCH[3]:-}" | trim_whitespace)"
      smartctl_scan_devices+=("$device")
      smartctl_args_by_device["$device"]="$args"
    fi
  done < <("$smartctl_bin" --scan-open 2>/dev/null || true)
}

smartctl_args_json_for_actual() {
  local actual_path="$1"
  local args=""

  if [[ -n "$actual_path" ]]; then
    args="${smartctl_args_by_device[$actual_path]:-}"
  fi

  jq -nc --arg args "$args" '
    if $args == "" then
      []
    else
      ($args | split(" ") | map(select(length > 0)))
    end
  '
}

disk_id_for_smart_device() {
  local smart_device="$1"
  if [[ "$smart_device" == "$by_id_dir/"* ]]; then
    basename "$smart_device"
  fi
}

build_disk_json() {
  local label="$1"
  local group="$2"
  local actual_device="$3"
  local smart_device="$4"
  local pool_member_path="${5:-}"
  local pool_name="${6:-}"
  local disk_id="${7:-}"
  local smartctl_args_json

  smartctl_args_json="$(smartctl_args_json_for_actual "$actual_device")"
  jq -nc \
    --arg label "$label" \
    --arg group "$group" \
    --arg actualDevice "$actual_device" \
    --arg smartDevice "$smart_device" \
    --arg device "$smart_device" \
    --arg poolMemberPath "$pool_member_path" \
    --arg pool "$pool_name" \
    --arg diskId "$disk_id" \
    --argjson smartctlArgs "$smartctl_args_json" \
    '{
      label: $label,
      group: $group,
      actualDevice: $actualDevice,
      smartDevice: $smartDevice,
      device: $device,
      smartctlArgs: $smartctlArgs
    }
    + (if $diskId == "" then {} else { diskId: $diskId } end)
    + (if $poolMemberPath == "" then {} else { poolMemberPath: $poolMemberPath } end)
    + (if $pool == "" then {} else { pool: $pool } end)'
}

append_unique_disk_json() {
  local array_name="$1"
  local smart_device="$2"
  local json="$3"
  local -n target_array="$array_name"

  if [[ -n "${seen_smart_device[$smart_device]:-}" ]]; then
    return 0
  fi

  seen_smart_device["$smart_device"]=1
  target_array+=("$json")
}

config_json="$(load_discovery_config_json)"
storage_profile="$(jq -r '.storageProfile // "zfs-mirror"' <<<"$config_json")"
system_disk_id="$(jq -r '.systemDisk.diskId // empty' <<<"$config_json")"
data_pool_name="$(jq -r '.dataPool.name // empty' <<<"$config_json")"

if [[ "$storage_profile" == "zfs-mirror" ]]; then
  command -v "$zpool_bin" >/dev/null 2>&1 || {
    echo "❌ Required command not found: $zpool_bin" >&2
    exit 1
  }
else
  data_pool_name=""
fi

smartctl_scan_load

system_disk_json=""
system_actual_device=""
if [[ -n "$system_disk_id" ]]; then
  system_smart_device="${by_id_dir}/${system_disk_id}"
  system_actual_device="$(actual_disk_for_path "$system_smart_device")"
  if [[ -n "$system_actual_device" ]]; then
    if preferred_system_smart_device="$(preferred_whole_disk_by_id_for_actual "$system_actual_device" 2>/dev/null)"; then
      system_smart_device="$preferred_system_smart_device"
    elif [[ "$system_actual_device" != "$system_smart_device" ]]; then
      system_smart_device="$system_actual_device"
    fi
  fi
  system_disk_json="$(build_disk_json "system" "system" "$system_actual_device" "$system_smart_device" "" "" "$system_disk_id")"
  seen_smart_device["$system_smart_device"]=1
fi

zfs_data_disk_json=()
if [[ -n "$data_pool_name" ]]; then
  data_index=0
  while IFS= read -r pool_member_path; do
    [[ -n "$pool_member_path" ]] || continue
    actual_device="$(actual_disk_for_path "$pool_member_path")"
    [[ -n "$actual_device" ]] || continue
    zfs_data_actual_devices["$actual_device"]=1
    smart_device="$actual_device"
    if preferred_smart_device="$(preferred_whole_disk_by_id_for_actual "$actual_device" 2>/dev/null)"; then
      smart_device="$preferred_smart_device"
    fi
    data_index=$((data_index + 1))
    disk_json="$(build_disk_json "data${data_index}" "zfs-data" "$actual_device" "$smart_device" "$pool_member_path" "$data_pool_name" "$(disk_id_for_smart_device "$smart_device")")"
    append_unique_disk_json zfs_data_disk_json "$smart_device" "$disk_json"
  done < <("$zpool_bin" status -P "$data_pool_name" 2>/dev/null | awk '$1 ~ /^\// { print $1 }')
fi

other_disk_json=()
other_index=0
for actual_device in "${smartctl_scan_devices[@]}"; do
  [[ -n "$actual_device" ]] || continue
  if [[ -n "$system_actual_device" && "$actual_device" == "$system_actual_device" ]]; then
    continue
  fi
  if [[ -n "${zfs_data_actual_devices[$actual_device]:-}" ]]; then
    continue
  fi

  smart_device="$actual_device"
  if preferred_smart_device="$(preferred_whole_disk_by_id_for_actual "$actual_device" 2>/dev/null)"; then
    smart_device="$preferred_smart_device"
  fi

  other_index=$((other_index + 1))
  other_disk_spec="$(build_disk_json "other${other_index}" "other" "$actual_device" "$smart_device" "" "" "$(disk_id_for_smart_device "$smart_device")")"
  append_unique_disk_json other_disk_json "$smart_device" "$other_disk_spec"
done

zfs_data_json="$(if ((${#zfs_data_disk_json[@]} == 0)); then jq -nc '[]'; else printf '%s\n' "${zfs_data_disk_json[@]}" | jq -sc '.'; fi)"
other_json="$(if ((${#other_disk_json[@]} == 0)); then jq -nc '[]'; else printf '%s\n' "${other_disk_json[@]}" | jq -sc '.'; fi)"
all_json="$(
  jq -nc \
    --argjson systemDisk "${system_disk_json:-null}" \
    --argjson zfsDataDisks "$zfs_data_json" \
    --argjson otherDisks "$other_json" '
      (
        (if $systemDisk == null then [] else [$systemDisk] end)
        + $zfsDataDisks
        + $otherDisks
      )
    '
)"

output_json="$(
  jq -nc \
    --argjson systemDisk "${system_disk_json:-null}" \
    --argjson zfsDataDisks "$zfs_data_json" \
    --argjson otherDisks "$other_json" \
    --argjson allSmartDisks "$all_json" '
      {
        systemDisk: $systemDisk,
        zfsDataDisks: $zfsDataDisks,
        otherDisks: $otherDisks,
        allSmartDisks: $allSmartDisks
      }
    '
)"

if [[ "$format" == "json" ]]; then
  printf '%s\n' "$output_json"
else
  jq -r '
    [
      (.systemDisk | select(. != null)),
      (.zfsDataDisks[]?),
      (.otherDisks[]?)
    ]
    | .[]
    | "\(.group)\t\(.label)\t\(.smartDevice)"
  ' <<<"$output_json"
fi
