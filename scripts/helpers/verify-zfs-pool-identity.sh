#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: verify-zfs-pool-identity.sh --pool NAME [OPTIONS]

Verify that an already-imported ZFS pool is the configured data pool before
any dataset or property reconciliation is allowed.

Options:
  --expected-guid GUID       Expected numeric ZFS pool GUID.
  --expected-device PATH     Configured whole-disk member; repeat as needed.

The transient kernel argument zfs_recovery_import=1 permits an explicit,
operator-observed recovery override. It never changes the configured identity,
so the next normal boot verifies the pool again.
EOF
}

pool=""
expected_guid=""
declare -a expected_devices=()

while (($# > 0)); do
  case "$1" in
    --pool)
      pool="${2:-}"
      shift 2
      ;;
    --expected-guid)
      expected_guid="${2:-}"
      shift 2
      ;;
    --expected-device)
      expected_devices+=("${2:-}")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -n "$pool" ]] || { echo "--pool is required" >&2; exit 2; }
if [[ -n "$expected_guid" && ! "$expected_guid" =~ ^[0-9]+$ ]]; then
  echo "--expected-guid must be a numeric ZFS pool GUID" >&2
  exit 2
fi
for device in "${expected_devices[@]}"; do
  [[ "$device" == /dev/disk/by-id/* ]] || {
    echo "Configured ZFS member must use /dev/disk/by-id: $device" >&2
    exit 2
  }
done

zpool_bin="${ZFS_POOL_IDENTITY_ZPOOL_BIN:-zpool}"
realpath_bin="${ZFS_POOL_IDENTITY_REALPATH_BIN:-realpath}"
awk_bin="${ZFS_POOL_IDENTITY_AWK_BIN:-awk}"
lsblk_bin="${ZFS_POOL_IDENTITY_LSBLK_BIN:-lsblk}"
cmdline_file="${ZFS_POOL_IDENTITY_CMDLINE_FILE:-/proc/cmdline}"
recovery_override=false

if [[ -r "$cmdline_file" ]]; then
  read -r -a kernel_options <"$cmdline_file" || true
  for option in "${kernel_options[@]:-}"; do
    case "$option" in
      zfs_recovery_import|zfs_recovery_import=1|zfs_recovery_import=y)
        recovery_override=true
        ;;
    esac
  done
fi

reject_or_override() {
  local message="$1"
  if [[ "$recovery_override" == true ]]; then
    echo "WARNING: $message" >&2
    echo "WARNING: continuing only because zfs_recovery_import=1 was supplied for this boot" >&2
    return 0
  fi
  echo "Refusing data-pool reconciliation: $message" >&2
  echo "For a deliberate recovery boot, append zfs_recovery_import=1 once and update the declarative pool identity immediately afterward." >&2
  return 1
}

current_guid="$($zpool_bin get -H -o value guid "$pool")"
if [[ ! "$current_guid" =~ ^[0-9]+$ ]]; then
  reject_or_override "pool $pool returned an invalid GUID: $current_guid"
fi

if [[ -n "$expected_guid" && "$current_guid" != "$expected_guid" ]]; then
  reject_or_override "pool $pool has GUID $current_guid, expected $expected_guid"
fi

declare -A expected_identities=()
whole_disk_path() {
  local path="$1"
  local canonical parent
  canonical="$($realpath_bin -m -- "$path")"
  parent="$($lsblk_bin -ndo PKNAME -- "$canonical" 2>/dev/null || true)"
  if [[ -n "$parent" ]]; then
    printf '/dev/%s\n' "${parent##*/}"
  else
    printf '%s\n' "$canonical"
  fi
}

for device in "${expected_devices[@]}"; do
  expected_identity="$device"
  if canonical="$($realpath_bin -e -- "$device" 2>/dev/null)"; then
    expected_identity="$(whole_disk_path "$canonical")"
  fi
  expected_identities["$expected_identity"]=1
done

actual_count=0
matched_count=0
declare -A matched_expected_identities=()
declare -a unexpected_devices=()
while IFS= read -r device; do
  [[ -n "$device" ]] || continue
  actual_count=$((actual_count + 1))
  canonical="$(whole_disk_path "$device")"
  if [[ -n "${expected_identities[$canonical]:-}" ]]; then
    matched_expected_identities["$canonical"]=1
    matched_count=$((matched_count + 1))
  elif [[ -n "${expected_identities[$device]:-}" ]]; then
    matched_expected_identities["$device"]=1
    matched_count=$((matched_count + 1))
  else
    unexpected_devices+=("$device")
  fi
done < <(
  "$zpool_bin" status -LP "$pool" \
    | "$awk_bin" '$1 ~ "^/dev/" { print $1 }'
)

if ((${#expected_devices[@]} == 0)); then
  if [[ -z "$expected_guid" ]]; then
    reject_or_override "neither an expected GUID nor configured member devices are available for pool $pool"
  fi
elif ((actual_count == 0 || matched_count == 0)); then
  reject_or_override "pool $pool exposes no member matching the configured by-id topology"
elif ((${#unexpected_devices[@]} > 0)); then
  reject_or_override "pool $pool contains unconfigured member path(s): ${unexpected_devices[*]}"
elif [[ -z "$expected_guid" ]] \
  && ((${#matched_expected_identities[@]} != ${#expected_identities[@]})); then
  reject_or_override "unpinned pool $pool does not expose every configured member; refusing to trust a partial topology before its GUID is pinned"
fi

if [[ -z "$expected_guid" ]]; then
  echo "Verified ZFS pool $pool GUID $current_guid from its configured by-id topology. Set storage.dataPool.expectedGuid = \"$current_guid\" to pin its immutable identity." >&2
else
  echo "Verified ZFS pool $pool GUID $current_guid and configured by-id topology." >&2
fi
