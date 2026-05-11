#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$script_dir/helpers/repo-common.sh" ]]; then
  source "$script_dir/helpers/repo-common.sh"
elif [[ -n "${BACKUP_TARGET_REPO_ROOT:-}" && -f "${BACKUP_TARGET_REPO_ROOT}/scripts/helpers/repo-common.sh" ]]; then
  source "${BACKUP_TARGET_REPO_ROOT}/scripts/helpers/repo-common.sh"
else
  echo "❌ Could not locate scripts/helpers/repo-common.sh." >&2
  exit 1
fi

init_repo_root "BACKUP_TARGET_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

dev_disk_root="${BACKUP_TARGET_DEV_DISK_ROOT:-/dev/disk}"
by_id_dir="${dev_disk_root}/by-id"
state_dir="${BACKUP_TARGET_STATE_DIR:-/persist/appdata/.nixos-managed/system-state-backup-device-selection}"
state_file="${state_dir}/selected-device"
mount_point="${BACKUP_TARGET_MOUNT_POINT:-/mnt/backup-system-state}"
repository_path="${mount_point}/restic/system-state"

supported_fs_types=(exfat ext4 btrfs)
partition_inventory_cache=""
protected_disks_cache=""

need nix jq lsblk findmnt mount umount install readlink

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

usage() {
  cat <<'EOF'
Usage: scripts/manage-backup-target.sh <list|status|select|mount|unmount|clear> [selector]

Manage the runtime-selected external USB partition used for system-state Restic
backups.

Selectors accepted by 'select':
  /dev/disk/by-id/...-partN
  UUID=<uuid>
  LABEL=<label>
If no selector is provided to 'select', an interactive picker is shown (TTY-only).

Examples:
  scripts/manage-backup-target.sh list
  scripts/manage-backup-target.sh status
  sudo scripts/manage-backup-target.sh select /dev/disk/by-id/<usb-backup>-part1
  sudo scripts/manage-backup-target.sh select
  sudo scripts/manage-backup-target.sh mount
EOF
}

protected_disks_json() {
  if [[ -z "$protected_disks_cache" ]]; then
    protected_disks_cache="$(
      STORAGE_DEVICE_DISCOVERY_REPO_ROOT="$repo_root" \
      STORAGE_DEVICE_DISCOVERY_DEV_DISK_ROOT="$dev_disk_root" \
      bash "$repo_root/scripts/discover-storage-devices.sh" --format json \
        | jq '
          {
            mainDisk: (.systemDisk.diskId // ""),
            zfsDataActualDevices: (.zfsDataDisks | map(.actualDevice))
          }
        '
    )"
  fi

  printf '%s\n' "$protected_disks_cache"
}

partition_inventory_json() {
  if [[ -z "$partition_inventory_cache" ]]; then
    partition_inventory_cache="$(
      lsblk -J --tree -p -o PATH,TYPE,TRAN,FSTYPE,LABEL,UUID,SIZE,MODEL,SERIAL,MOUNTPOINTS \
        | jq '
          [
            .blockdevices[]
            | select(.type == "disk")
            | . as $disk
            | ($disk.children // [])[]
            | select(.type == "part")
            | {
                path: .path,
                tran: ($disk.tran // ""),
                fstype: (.fstype // ""),
                label: (.label // ""),
                uuid: (.uuid // ""),
                size: (.size // ""),
                model: ($disk.model // ""),
                serial: ($disk.serial // ""),
                mountpoints: ((.mountpoints // []) | map(select(type == "string" and . != "")))
              }
          ]
        '
    )"
  fi

  printf '%s\n' "$partition_inventory_cache"
}

supported_fs_type() {
  local fstype="$1"
  local candidate
  for candidate in "${supported_fs_types[@]}"; do
    if [[ "$candidate" == "$fstype" ]]; then
      return 0
    fi
  done
  return 1
}

mount_options_for_fstype() {
  local fstype="$1"

  case "$fstype" in
    exfat)
      printf '%s\n' 'uid=0,gid=0,fmask=0177,dmask=0077,nodev,nosuid,noexec,noatime'
      ;;
    ext4|btrfs)
      printf '%s\n' 'nodev,nosuid,noexec,noatime'
      ;;
    *)
      echo "❌ Unsupported filesystem type: ${fstype}" >&2
      exit 1
      ;;
  esac
}

selected_device_or_empty() {
  if [[ -r "$state_file" ]]; then
    tr -d '\n' < "$state_file"
  fi
}

partition_by_id_candidates() {
  local actual_path="$1"
  local link
  local target

  shopt -s nullglob
  for link in "$by_id_dir"/*; do
    [[ -L "$link" ]] || continue
    target="$(readlink -f "$link" 2>/dev/null || true)"
    if [[ "$target" == "$actual_path" && "$(basename "$link")" =~ -part[0-9]+$ ]]; then
      printf '%s\n' "$link"
    fi
  done
  shopt -u nullglob
}

preferred_by_id_for_actual_path() {
  local actual_path="$1"
  local candidate
  local fallback=""

  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    if [[ "$(basename "$candidate")" == usb-* ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi

    if [[ -z "$fallback" && "$(basename "$candidate")" != wwn-* ]]; then
      fallback="$candidate"
    fi

    if [[ -z "$fallback" ]]; then
      fallback="$candidate"
    fi
  done < <(partition_by_id_candidates "$actual_path")

  if [[ -n "$fallback" ]]; then
    printf '%s\n' "$fallback"
    return 0
  fi

  return 1
}

device_info_json() {
  local actual_path="$1"
  partition_inventory_json | jq -e --arg path "$actual_path" '.[] | select(.path == $path)'
}

device_is_protected() {
  local actual_path="$1"
  local protected_json
  local candidate
  local disk_id
  local whole_disk_link
  local whole_disk_actual

  protected_json="$(protected_disks_json)"
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    disk_id="$(basename "$candidate")"
    disk_id="${disk_id%-part*}"
    whole_disk_link="${by_id_dir}/${disk_id}"
    whole_disk_actual="$(readlink -f "$whole_disk_link" 2>/dev/null || true)"
    if jq -e --arg disk_id "$disk_id" --arg actual "$whole_disk_actual" '
      .mainDisk == $disk_id
      or (.zfsDataActualDevices | index($actual) != null)
    ' >/dev/null <<<"$protected_json"; then
      return 0
    fi
  done < <(partition_by_id_candidates "$actual_path")

  return 1
}

resolve_selector_to_actual_path() {
  local selector="$1"
  local inventory_json
  local selection_json
  local match_count

  inventory_json="$(partition_inventory_json)"
  if [[ "$selector" == /* ]]; then
    if [[ ! -e "$selector" ]]; then
      echo "❌ Device path not found: ${selector}" >&2
      exit 1
    fi

    readlink -f "$selector"
    return 0
  fi

  if [[ "$selector" == UUID=* ]]; then
    selection_json="$(jq -c --arg uuid "${selector#UUID=}" '[ .[] | select(.uuid == $uuid) ]' <<<"$inventory_json")"
  elif [[ "$selector" == LABEL=* ]]; then
    selection_json="$(jq -c --arg label "${selector#LABEL=}" '[ .[] | select(.label == $label) ]' <<<"$inventory_json")"
  else
    echo "❌ Unsupported selector: ${selector}" >&2
    exit 1
  fi

  match_count="$(jq 'length' <<<"$selection_json")"
  if [[ "$match_count" == "0" ]]; then
    echo "❌ No partition matched selector: ${selector}" >&2
    exit 1
  fi

  if [[ "$match_count" != "1" ]]; then
    echo "❌ Selector is ambiguous: ${selector}" >&2
    jq -r '.[] | "- \(.path) (\(.fstype // "unknown"), label=\(.label // "-"), uuid=\(.uuid // "-"))"' <<<"$selection_json" >&2
    exit 1
  fi

  jq -r '.[0].path' <<<"$selection_json"
}

canonical_device_for_selector() {
  local selector="$1"
  local actual_path
  local device_info
  local tran
  local fstype
  local by_id_path

  actual_path="$(resolve_selector_to_actual_path "$selector")"
  device_info="$(device_info_json "$actual_path")"
  tran="$(jq -r '.tran' <<<"$device_info")"
  fstype="$(jq -r '.fstype' <<<"$device_info")"

  if [[ "$tran" != "usb" ]]; then
    echo "❌ Backup targets must be USB partitions: ${selector}" >&2
    exit 1
  fi

  if ! supported_fs_type "$fstype"; then
    echo "❌ Unsupported backup target filesystem: ${fstype:-missing}" >&2
    exit 1
  fi

  if device_is_protected "$actual_path"; then
    echo "❌ Refusing to select a protected system or pool device: ${selector}" >&2
    exit 1
  fi

  if ! by_id_path="$(preferred_by_id_for_actual_path "$actual_path")"; then
    echo "❌ Could not find a stable /dev/disk/by-id partition path for: ${actual_path}" >&2
    exit 1
  fi

  printf '%s\n' "$by_id_path"
}

persist_selected_device() {
  local canonical_device="$1"

  "${sudo_cmd[@]}" install -d -m 0755 "$state_dir"
  printf '%s\n' "$canonical_device" | "${sudo_cmd[@]}" tee "$state_file" >/dev/null
  "${sudo_cmd[@]}" chmod 0644 "$state_file"
}

mounted_source_or_empty() {
  local mount_info mount_target mount_source _
  mount_info="$(findmnt -rn -o TARGET,SOURCE,FSTYPE --target "$mount_point" 2>/dev/null || true)"
  [[ -n "$mount_info" ]] || return 0
  read -r mount_target mount_source _ <<<"$mount_info"
  if [[ "$mount_target" == "$mount_point" ]]; then
    printf '%s\n' "$mount_source"
  fi
}

mounted_fstype_or_empty() {
  local mount_info mount_target _ mount_fstype
  mount_info="$(findmnt -rn -o TARGET,SOURCE,FSTYPE --target "$mount_point" 2>/dev/null || true)"
  [[ -n "$mount_info" ]] || return 0
  read -r mount_target _ mount_fstype <<<"$mount_info"
  if [[ "$mount_target" == "$mount_point" ]]; then
    printf '%s\n' "$mount_fstype"
  fi
}

list_candidates() {
  local selected_device
  local candidate_json
  local actual_path
  local by_id_path
  local fstype
  local selected_flag

  selected_device="$(selected_device_or_empty)"
  echo "eligible backup targets:"

  while IFS= read -r candidate_json; do
    [[ -n "$candidate_json" ]] || continue
    actual_path="$(jq -r '.path' <<<"$candidate_json")"
    fstype="$(jq -r '.fstype' <<<"$candidate_json")"

    if ! supported_fs_type "$fstype"; then
      continue
    fi

    if device_is_protected "$actual_path"; then
      continue
    fi

    if ! by_id_path="$(preferred_by_id_for_actual_path "$actual_path" 2>/dev/null)"; then
      continue
    fi

    selected_flag="no"
    if [[ "$selected_device" == "$by_id_path" ]]; then
      selected_flag="yes"
    fi

    printf '%s\n' \
      "selected=${selected_flag} device=${by_id_path} fstype=${fstype} label=$(jq -r '.label // "-"' <<<"$candidate_json") uuid=$(jq -r '.uuid // "-"' <<<"$candidate_json") size=$(jq -r '.size // "-"' <<<"$candidate_json") model=$(jq -r '.model // "-"' <<<"$candidate_json") serial=$(jq -r '.serial // "-"' <<<"$candidate_json") mountpoints=$(jq -r 'if (.mountpoints | length) == 0 then "-" else (.mountpoints | join(",")) end' <<<"$candidate_json")"
  done < <(partition_inventory_json | jq -c '.[] | select(.tran == "usb")')
}

select_candidate_interactively() {
  if [[ ! -t 0 ]]; then
    echo "❌ Interactive selection requires a terminal. Provide a selector argument instead." >&2
    echo "Examples: /dev/disk/by-id/<usb-backup>-part1, UUID=<uuid>, LABEL=<label>" >&2
    return 1
  fi

  local selected_device
  local candidate_json
  local actual_path
  local by_id_path
  local fstype
  local size
  local label
  local uuid
  local model
  local serial
  local mountpoints
  local selected_flag
  local index=0
  local choice
  local -a candidates=()

  selected_device="$(selected_device_or_empty)"
  echo "Eligible backup devices:"

  while IFS= read -r candidate_json; do
    [[ -n "$candidate_json" ]] || continue
    actual_path="$(jq -r '.path' <<<"$candidate_json")"
    fstype="$(jq -r '.fstype' <<<"$candidate_json")"

    if ! supported_fs_type "$fstype"; then
      continue
    fi

    if device_is_protected "$actual_path"; then
      continue
    fi

    if ! by_id_path="$(preferred_by_id_for_actual_path "$actual_path" 2>/dev/null)"; then
      continue
    fi

    selected_flag=" "
    if [[ "$selected_device" == "$by_id_path" ]]; then
      selected_flag="*"
    fi

    size="$(jq -r '.size // "-"' <<<"$candidate_json")"
    label="$(jq -r '.label // \"-\"' <<<"$candidate_json")"
    uuid="$(jq -r '.uuid // \"-\"' <<<"$candidate_json")"
    model="$(jq -r '.model // \"-\"' <<<"$candidate_json")"
    serial="$(jq -r '.serial // \"-\"' <<<"$candidate_json")"
    mountpoints="$(jq -r 'if (.mountpoints | length) == 0 then \"-\" else (.mountpoints | join(\",\")) end' <<<"$candidate_json")"

    ((index += 1))
    candidates+=("$by_id_path")
    printf '[%d] %s path=%s size=%s fstype=%s label=%s uuid=%s model=%s serial=%s mounted=%s\n' \
      "$index" "$selected_flag" "$by_id_path" "$size" "$fstype" "$label" "$uuid" "$model" "$serial" "$mountpoints"
  done < <(partition_inventory_json | jq -c '.[] | select(.tran == "usb")')

  if (( index == 0 )); then
    echo "❌ No eligible USB backup targets were found."
    return 1
  fi

  while true; do
    printf 'Select a target [1-%d] (or q to cancel): ' "$index"
    if ! read -r choice; then
      echo "❌ No selection received."
      return 1
    fi

    if [[ "$choice" == "q" || "$choice" == "Q" || "$choice" == "quit" ]]; then
      echo "selection cancelled"
      return 1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= index )); then
      printf '%s\n' "${candidates[$((choice - 1))]}"
      return 0
    fi

    echo "❌ Invalid choice: ${choice}"
  done
}

status_target() {
  local selected_device
  local selected_real=""
  local attached="false"
  local mount_source
  local mount_fstype

  selected_device="$(selected_device_or_empty)"
  if [[ -n "$selected_device" ]]; then
    selected_real="$(readlink -f "$selected_device" 2>/dev/null || true)"
    if [[ -n "$selected_real" && -e "$selected_real" ]]; then
      attached="true"
    fi
  fi

  mount_source="$(mounted_source_or_empty)"
  mount_fstype="$(mounted_fstype_or_empty)"

  echo "selected_device: ${selected_device:-none}"
  echo "selected_attached: ${attached}"
  if [[ -n "$mount_source" ]]; then
    echo "mount_status: mounted"
    echo "mounted_source: ${mount_source}"
    echo "mounted_fstype: ${mount_fstype:-unknown}"
    if [[ -d "$repository_path" ]]; then
      echo "repository_status: present"
    else
      echo "repository_status: missing"
    fi
  else
    echo "mount_status: unmounted"
    echo "repository_status: unavailable"
  fi
}

mount_selected_target() {
  local selected_device
  local selected_real
  local device_info
  local fstype
  local options
  local mount_source
  local mount_real

  selected_device="$(selected_device_or_empty)"
  if [[ -z "$selected_device" ]]; then
    echo "❌ No backup target is selected. Use scripts/manage-backup-target.sh select first." >&2
    exit 1
  fi

  if [[ ! -e "$selected_device" ]]; then
    echo "❌ Selected backup target is not attached: ${selected_device}" >&2
    exit 1
  fi

  selected_real="$(readlink -f "$selected_device" 2>/dev/null || true)"
  device_info="$(device_info_json "$selected_real")"
  fstype="$(jq -r '.fstype' <<<"$device_info")"

  if ! supported_fs_type "$fstype"; then
    echo "❌ Unsupported backup target filesystem: ${fstype:-missing}" >&2
    exit 1
  fi

  "${sudo_cmd[@]}" install -d -m 0700 "$mount_point"

  mount_source="$(mounted_source_or_empty)"
  if [[ -n "$mount_source" ]]; then
    mount_real="$(readlink -f "$mount_source" 2>/dev/null || printf '%s' "$mount_source")"
    if [[ "$mount_real" == "$selected_real" ]]; then
      return 0
    fi

    echo "❌ ${mount_point} is already mounted from another source: ${mount_source}" >&2
    exit 1
  fi

  options="$(mount_options_for_fstype "$fstype")"
  "${sudo_cmd[@]}" mount -t "$fstype" -o "$options" "$selected_device" "$mount_point"
}

unmount_selected_target() {
  if [[ -n "$(mounted_source_or_empty)" ]]; then
    "${sudo_cmd[@]}" umount "$mount_point"
  fi
}

clear_selection() {
  unmount_selected_target
  if [[ -e "$state_file" ]]; then
    "${sudo_cmd[@]}" rm -f "$state_file"
  fi
}

  case "${1:-}" in
  -h|--help)
    usage
    ;;
  list)
    list_candidates
    ;;
  status)
    status_target
    ;;
  select)
    if (( $# > 2 )); then
      usage >&2
      exit 1
    fi

    if (( $# == 1 )); then
      canonical_device="$(select_candidate_interactively)"
    else
      canonical_device="$(canonical_device_for_selector "$2")"
    fi
    persist_selected_device "$canonical_device"
    status_target
    ;;
  mount)
    mount_selected_target
    ;;
  unmount)
    unmount_selected_target
    ;;
  clear)
    clear_selection
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
