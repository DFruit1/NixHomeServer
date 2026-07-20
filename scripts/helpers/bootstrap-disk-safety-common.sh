#!/usr/bin/env bash

# Validate the ZFS identity transition before a Disko plan can inspect or erase
# hardware. A full blank-disk run creates a new pool and therefore cannot keep
# an old GUID pin. Conversely, system-disk-only recovery preserves an existing
# pool and must have its immutable identity pinned before the system SSD is
# replaced.
bootstrap_validate_zfs_guid_for_disko_mode() {
  local storage_profile="$1"
  local system_disk_only="$2"
  # 0 = null, 1 = string, 2 = configured with a non-string JSON type.
  local expected_guid_state="$3"
  local expected_guid="$4"

  [[ "$storage_profile" == "zfs-mirror" ]] || return 0
  case "$system_disk_only" in
    0|1) ;;
    *)
      echo "Invalid internal system-disk-only mode: ${system_disk_only}" >&2
      return 2
      ;;
  esac
  case "$expected_guid_state" in
    0|1|2) ;;
    *)
      echo "Invalid internal expected-GUID state: ${expected_guid_state}" >&2
      return 2
      ;;
  esac

  if [[ "$system_disk_only" == 0 && "$expected_guid_state" != 0 ]]; then
    echo "❌ Full blank-disk bootstrap for zfs-mirror requires storage.dataPool.expectedGuid = null because Disko creates a new pool GUID." >&2
    echo "   Set storage.dataPool.expectedGuid = null, commit that bootstrap revision, and rerun the guarded plan." >&2
    return 1
  fi
  if [[ "$system_disk_only" == 1 && "$expected_guid_state" == 0 ]]; then
    echo "❌ --system-disk-only requires a committed non-null storage.dataPool.expectedGuid for the pool being preserved." >&2
    echo "   Verify and pin the existing pool's numeric GUID, then commit the recovery revision before replacing the system disk." >&2
    return 1
  fi
  if [[ "$expected_guid_state" != 0 ]] \
    && [[ "$expected_guid_state" != 1 || ! "$expected_guid" =~ ^[0-9]+$ ]]; then
    echo "❌ storage.dataPool.expectedGuid must be null or a numeric ZFS pool GUID encoded as a string." >&2
    return 1
  fi
}

# Return success only when two regular files are backed by different
# filesystem device IDs. A bind mount on the same filesystem therefore does
# not qualify as a second durable copy.
bootstrap_files_use_distinct_filesystems() {
  local first_file="$1"
  local second_file="$2"
  local stat_bin="${BOOTSTRAP_SAFETY_STAT_BIN:-stat}"
  local first_device second_device

  first_device="$("$stat_bin" -c %d -- "$first_file")" || return 2
  second_device="$("$stat_bin" -c %d -- "$second_file")" || return 2
  [[ -n "$first_device" && -n "$second_device" && "$first_device" != "$second_device" ]]
}

# Return 0 when BACKUP_FILE ultimately resides on one of the selected whole
# disks, 1 when its resolved block ancestry is disjoint (or it is a non-block
# network source), and 2 when a local block source cannot be resolved safely.
bootstrap_backup_uses_selected_disk() {
  local backup_file="$1"
  shift
  local findmnt_bin="${BOOTSTRAP_SAFETY_FINDMNT_BIN:-findmnt}"
  local lsblk_bin="${BOOTSTRAP_SAFETY_LSBLK_BIN:-lsblk}"
  local readlink_bin="${BOOTSTRAP_SAFETY_READLINK_BIN:-readlink}"
  local source fstype canonical_source backing_nodes node type canonical_node selected

  read -r source fstype < <("$findmnt_bin" -n -o SOURCE,FSTYPE -T "$backup_file") || return 2
  source="${source%%\[*}"
  [[ -n "$source" && -n "$fstype" ]] || return 2
  case "$source" in
    /dev/*) ;;
    *)
      case "$fstype" in
        nfs|nfs4|cifs|sshfs|fuse.sshfs|9p|ceph|glusterfs) return 1 ;;
        *) return 2 ;;
      esac
      ;;
  esac

  canonical_source="$("$readlink_bin" -f -- "$source")" || return 2
  [[ -n "$canonical_source" ]] || return 2
  backing_nodes="$("$lsblk_bin" --inverse -nrpo NAME,TYPE "$canonical_source" 2>/dev/null)" || return 2
  [[ -n "$backing_nodes" ]] || return 2

  while read -r node type; do
    [[ "$type" == "disk" && -n "$node" ]] || continue
    canonical_node="$("$readlink_bin" -f -- "$node")" || return 2
    for selected in "$@"; do
      if [[ "$canonical_node" == "$selected" ]]; then
        return 0
      fi
    done
  done <<<"$backing_nodes"
  return 1
}

# Print registered LVM PV paths and their volume groups as pipe-separated
# records. An orphan PV has an empty second field. Return 2 rather than an
# empty inventory when LVM cannot be queried, because an empty result and a
# failed query have very different safety meanings before a wipe.
bootstrap_query_lvm_pv_records() {
  local pvs_bin="${BOOTSTRAP_SAFETY_PVS_BIN:-pvs}"
  local output

  if ! output="$("$pvs_bin" --readonly --noheadings --separator '|' -o pv_name,vg_name 2>&1)"; then
    echo "LVM inventory query failed: $output" >&2
    return 2
  fi
  printf '%s\n' "$output" | awk -F '|' '
    {
      if ($0 ~ /^[[:space:]]*$/) next
      if (NF != 2) {
        print "Malformed LVM PV inventory record: " $0 > "/dev/stderr"
        invalid = 1
        next
      }
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
      if ($1 != "") print $1 "|" $2
    }
    END { if (invalid) exit 2 }
  '
}

# Return 0 only when every logical volume in VG is explicitly reported as
# inactive (or the VG has no LVs), 1 when any LV is active, and 2 when the
# inventory is unavailable or ambiguous. Include hidden/internal LVs because
# those can still hold active device-mapper mappings on disks other than the
# selected PV.
bootstrap_lvm_vg_is_fully_inactive() {
  local vg="$1"
  local lvs_bin="${BOOTSTRAP_SAFETY_LVS_BIN:-lvs}"
  local output line record_vg active_state extra

  [[ -n "$vg" && "$vg" != *'|'* && "$vg" != *$'\n'* ]] || return 2
  if ! output="$("$lvs_bin" --readonly --all --noheadings --separator '|' -o vg_name,lv_active -- "$vg" 2>&1)"; then
    echo "LVM logical-volume query failed for volume group ${vg}: $output" >&2
    return 2
  fi

  while IFS= read -r line; do
    [[ -n "${line//[[:space:]]/}" ]] || continue
    [[ "$line" == *'|'* ]] || return 2
    IFS='|' read -r record_vg active_state extra <<<"$line"
    [[ -z "$extra" ]] || return 2
    record_vg="$(printf '%s' "$record_vg" | awk '{$1=$1; print}')"
    active_state="$(printf '%s' "$active_state" | awk '{$1=$1; print}')"
    [[ "$record_vg" == "$vg" ]] || return 2
    case "$active_state" in
      active) return 1 ;;
      inactive) ;;
      *) return 2 ;;
    esac
  done <<<"$output"

  # An empty, successful query means this volume group contains no LVs.
  return 0
}

# Print absolute member paths for every imported ZFS pool. Both pool listing
# and each status query are fail-closed so command failure cannot masquerade as
# “no imported pools”.
bootstrap_query_imported_zpool_paths() {
  local zpool_bin="${BOOTSTRAP_SAFETY_ZPOOL_BIN:-zpool}"
  local pools pool status_output

  if ! pools="$("$zpool_bin" list -H -o name 2>&1)"; then
    echo "ZFS imported-pool inventory query failed: $pools" >&2
    return 2
  fi
  while IFS= read -r pool; do
    [[ -n "$pool" ]] || continue
    if ! status_output="$("$zpool_bin" status -P "$pool" 2>&1)"; then
      echo "ZFS status query failed for imported pool ${pool}: $status_output" >&2
      return 2
    fi
    printf '%s\n' "$status_output" | awk '$1 ~ "^/" { print $1 }'
  done <<<"$pools"
}
