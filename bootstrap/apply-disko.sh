#!/usr/bin/env bash

set -euo pipefail

# shellcheck disable=SC1091 # Dynamic path; defines repo_root/status_blocked and reporting helpers.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/admin/common.sh"
# shellcheck disable=SC1091,SC2154 # repo_root is provided by common.sh above.
source "$repo_root/scripts/helpers/bootstrap-source-snapshot.sh"
# shellcheck disable=SC1091,SC2154 # repo_root is provided by common.sh above.
source "$repo_root/scripts/helpers/bootstrap-disk-safety-common.sh"

usage() {
  cat <<'EOF'
Usage:
  bootstrap/apply-disko.sh [--host <flake-hostname>]
  bootstrap/apply-disko.sh --host <flake-hostname> --apply \
    --identity <age-key> --age-key-backup <second-copy> \
    --confirm-host <flake-hostname> --confirm-disk <by-id-basename> [--confirm-disk ...] \
    [--allow-inactive-lvm-pv <by-id-basename> ...]

For a ZFS host whose system SSD alone is being replaced, add
--system-disk-only and --confirm-preserve-data-pool <pool-name>. That mode uses
a separate Disko output containing no data-pool devices.

Without --apply, print the exact pinned disko target and destructive disk set.
Applying is permitted only from a UEFI-booted installer, as root, when every
configured disk exists as an unmounted whole disk and is confirmed individually.
All selected disks are irreversibly erased.
EOF
}

host=""
apply=0
confirmed_host=""
confirmed_disks=()
allowed_inactive_lvm_pvs=()
identity_file=""
age_key_backup=""
allow_host_platform_mismatch=0
system_disk_only=0
confirmed_preserved_pool=""
while (($# > 0)); do
  case "$1" in
    --host)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --host requires a flake hostname." >&2; exit 1; }
      host="${2:-}"
      shift 2
      ;;
    --apply)
      apply=1
      shift
      ;;
    --identity)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --identity requires the installer copy of the private age key." >&2; exit 1; }
      identity_file="${2:-}"
      shift 2
      ;;
    --age-key-backup)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --age-key-backup requires a second private-key copy on separately mounted durable storage." >&2; exit 1; }
      age_key_backup="${2:-}"
      shift 2
      ;;
    --allow-host-platform-mismatch)
      allow_host_platform_mismatch=1
      shift
      ;;
    --system-disk-only)
      system_disk_only=1
      shift
      ;;
    --confirm-preserve-data-pool)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --confirm-preserve-data-pool requires the configured pool name." >&2; exit 1; }
      confirmed_preserved_pool="${2:-}"
      shift 2
      ;;
    --confirm-host)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --confirm-host requires a flake hostname." >&2; exit 1; }
      confirmed_host="${2:-}"
      shift 2
      ;;
    --confirm-disk)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --confirm-disk requires a by-id basename." >&2; exit 1; }
      confirmed_disks+=("${2:-}")
      shift 2
      ;;
    --allow-inactive-lvm-pv)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "❌ --allow-inactive-lvm-pv requires a by-id basename." >&2; exit 1; }
      allowed_inactive_lvm_pvs+=("${2:-}")
      shift 2
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
done

need age-keygen arping awk blockdev find findmnt grep ip jq lsblk lvs mktemp nix pvs readlink sed sort stat swapon tr uniq uname wipefs zpool
# shellcheck disable=SC2154 # status_blocked is maintained by need() from common.sh.
if ((status_blocked > 0)); then
  finish_report
fi

# Materialize the source exactly once, before deriving even the default host or
# reading any storage settings. Every later evaluation and build uses this
# immutable store snapshot, so edits to the checkout cannot change the plan
# after a user has reviewed its disks.
pin_bootstrap_source_snapshot "$NIXHOMESERVER_FLAKE_REF_FOR_EVAL"
pinned_source_path="$NIXHOMESERVER_PINNED_SOURCE_PATH"

[[ -n "$host" ]] || host="$(default_host)"
settings_json="$(nix_json_for_host "$host" "removeAttrs (builtins.getAttr hostName flake.lib.nixhomeserverSettings) [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"
active_secret_names_json="$(nix_json_for_host "$host" "builtins.attrNames cfg.age.secrets")"
configured_host="$(jq -r '.hostname' <<<"$settings_json")"
storage_profile="$(jq -r '.storageProfile' <<<"$settings_json")"
host_platform="$(jq -r '.hostPlatform' <<<"$settings_json")"
main_disk="$(jq -r '.mainDisk' <<<"$settings_json")"
lan_iface="$(jq -r '.netIface' <<<"$settings_json")"
lan_ip="$(jq -r '.serverLanIP' <<<"$settings_json")"
lan_gateway="$(jq -r '.networking.lan.gateway' <<<"$settings_json")"
data_pool_name="$(jq -r '.zfsDataPool.name' <<<"$settings_json")"
expected_data_pool_guid_state="$(
  jq -r '
    if .zfsDataPool.expectedGuid == null then 0
    elif (.zfsDataPool.expectedGuid | type) == "string" then 1
    else 2
    end
  ' <<<"$settings_json"
)"
expected_data_pool_guid="$(jq -r '.zfsDataPool.expectedGuid // ""' <<<"$settings_json")"
mapfile -t data_pool_disks < <(jq -r '.zfsDataPoolDiskIds[]' <<<"$settings_json")
if ! bootstrap_validate_zfs_guid_for_disko_mode \
  "$storage_profile" \
  "$system_disk_only" \
  "$expected_data_pool_guid_state" \
  "$expected_data_pool_guid"; then
  exit 1
fi
if ((system_disk_only == 1)); then
  if [[ "$storage_profile" != "zfs-mirror" ]]; then
    echo "❌ --system-disk-only cannot preserve data for ${storage_profile}; /mnt/data is on the system disk." >&2
    exit 1
  fi
  configured_disks=("$main_disk")
  disko_configuration_suffix="-system-recovery"
else
  mapfile -t configured_disks < <(jq -r '[.mainDisk] + (if .storageProfile == "zfs-mirror" then .zfsDataPoolDiskIds else [] end) | .[]' <<<"$settings_json")
  disko_configuration_suffix="-bootstrap"
fi

case "$(uname -m)" in
  x86_64) installer_platform="x86_64-linux" ;;
  aarch64|arm64) installer_platform="aarch64-linux" ;;
  *) installer_platform="unsupported-$(uname -m)" ;;
esac
if [[ "$installer_platform" != "$host_platform" && "$allow_host_platform_mismatch" -ne 1 ]]; then
  echo "❌ Installer architecture ${installer_platform} does not match target ${host_platform}." >&2
  echo "   Correct system.hostPlatform, or use --allow-host-platform-mismatch only with a tested remote builder/emulation setup." >&2
  exit 1
elif [[ "$installer_platform" != "$host_platform" ]]; then
  echo "⚠️  EXPERT OVERRIDE: installer architecture ${installer_platform} differs from target ${host_platform}." >&2
fi

if [[ "$configured_host" != "$host" ]]; then
  echo "❌ Flake host '${host}' evaluates settings for '${configured_host}'; refusing ambiguous disk bootstrap." >&2
  exit 1
fi

if ((${#configured_disks[@]} == 0)); then
  echo "❌ No disks are configured." >&2
  exit 1
fi

duplicate_ids="$(printf '%s\n' "${configured_disks[@]}" | sort | uniq -d)"
if [[ -n "$duplicate_ids" ]]; then
  echo "❌ A disk ID is selected more than once:" >&2
  printf '   %s\n' "$duplicate_ids" >&2
  exit 1
fi

duplicate_lvm_overrides="$(printf '%s\n' "${allowed_inactive_lvm_pvs[@]}" | sed '/^$/d' | sort | uniq -d)"
if [[ -n "$duplicate_lvm_overrides" ]]; then
  echo "❌ --allow-inactive-lvm-pv may name each selected disk only once:" >&2
  printf '   %s\n' "$duplicate_lvm_overrides" >&2
  exit 1
fi
for allowed_lvm_disk in "${allowed_inactive_lvm_pvs[@]}"; do
  if [[ "$allowed_lvm_disk" == */* ]] \
    || ! printf '%s\n' "${configured_disks[@]}" | grep -Fxq -- "$allowed_lvm_disk"; then
    echo "❌ --allow-inactive-lvm-pv must exactly name a configured selected by-id disk: ${allowed_lvm_disk}" >&2
    exit 1
  fi
done

declare -A canonical_disks=()
declare -A configured_canonical_by_id=()
declare -A configured_identity_by_id=()
declare -A preserved_canonical_disks=()
declare -A preserved_canonical_by_id=()
declare -A preserved_identity_by_id=()

assert_disk_is_idle() {
  local disk_path="$1"
  local canonical="$2"
  local stage="$3"
  local mounted node holder holder_dir swap_source canonical_source pv_source pv_vg pool_path configured_disk_id
  local swap_sources holder_paths pv_records pool_paths inventory_status lvm_vg_status
  local -A disk_nodes=()

  while IFS= read -r node; do
    [[ -n "$node" ]] && disk_nodes["$(readlink -f -- "$node")"]=1
  done < <(lsblk -nrpo NAME "$canonical")

  mounted="$(lsblk -nrpo MOUNTPOINTS "$canonical" | awk 'NF { print; exit }')"
  if [[ -n "$mounted" ]]; then
    echo "❌ Selected disk or one of its partitions is mounted during ${stage} (${mounted}): ${disk_path}" >&2
    return 1
  fi

  inventory_status=0
  swap_sources="$(swapon --noheadings --raw --show=NAME 2>&1)" || inventory_status=$?
  if ((inventory_status != 0)); then
    echo "❌ Could not inventory active swap during ${stage}: ${swap_sources}" >&2
    return 1
  fi
  while IFS= read -r swap_source; do
    [[ -n "$swap_source" ]] || continue
    canonical_source="$(readlink -f -- "$swap_source" 2>/dev/null || true)"
    if [[ -n "${disk_nodes[$canonical_source]:-}" ]]; then
      echo "❌ Selected disk provides active swap during ${stage}: ${swap_source}" >&2
      return 1
    fi
  done <<<"$swap_sources"

  for node in "${!disk_nodes[@]}"; do
    holder_dir="/sys/class/block/${node##*/}/holders"
    if [[ ! -d "$holder_dir" ]]; then
      echo "❌ Could not inspect block-device holders during ${stage}: ${holder_dir}" >&2
      return 1
    fi
    inventory_status=0
    holder_paths="$(find "$holder_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>&1)" \
      || inventory_status=$?
    if ((inventory_status != 0)); then
      echo "❌ Block-device holder inventory failed during ${stage}: ${holder_paths}" >&2
      return 1
    fi
    while IFS= read -r holder; do
      [[ -n "$holder" ]] || continue
      echo "❌ Selected disk has an active device-mapper/LVM/MD holder during ${stage}: ${node} -> ${holder}" >&2
      return 1
    done <<<"$holder_paths"
  done

  inventory_status=0
  pv_records="$(bootstrap_query_lvm_pv_records)" || inventory_status=$?
  if ((inventory_status != 0)); then
    echo "❌ Could not prove LVM is inactive on selected disks during ${stage}." >&2
    return 1
  fi
  while IFS='|' read -r pv_source pv_vg; do
    [[ -n "$pv_source" ]] || continue
    canonical_source="$(readlink -f -- "$pv_source" 2>/dev/null || true)"
    if [[ -n "${disk_nodes[$canonical_source]:-}" ]]; then
      configured_disk_id="${canonical_disks[$canonical]}"
      if printf '%s\n' "${allowed_inactive_lvm_pvs[@]}" | grep -Fxq -- "$configured_disk_id"; then
        if [[ -n "$pv_vg" ]]; then
          lvm_vg_status=0
          bootstrap_lvm_vg_is_fully_inactive "$pv_vg" || lvm_vg_status=$?
          if ((lvm_vg_status == 1)); then
            echo "❌ Selected disk belongs to LVM volume group ${pv_vg}, which has an active logical volume during ${stage}: ${pv_source}" >&2
            echo "   Deactivate the entire volume group before using --allow-inactive-lvm-pv." >&2
            return 1
          elif ((lvm_vg_status != 0)); then
            echo "❌ Could not prove every logical volume in LVM volume group ${pv_vg} is inactive during ${stage}." >&2
            return 1
          fi
        fi
        echo "⚠️  Selected disk has orphan or fully inactive LVM PV metadata explicitly approved for erasure during ${stage}: ${pv_source}" >&2
      else
        echo "❌ Selected disk is registered as an LVM physical volume during ${stage}: ${pv_source}" >&2
        echo "   Back it up, deactivate its entire volume group, and rerun with --allow-inactive-lvm-pv ${configured_disk_id} only if this exact PV is intentionally being erased." >&2
        return 1
      fi
    fi
  done <<<"$pv_records"

  inventory_status=0
  pool_paths="$(bootstrap_query_imported_zpool_paths)" || inventory_status=$?
  if ((inventory_status != 0)); then
    echo "❌ Could not prove ZFS is inactive on selected disks during ${stage}." >&2
    return 1
  fi
  while IFS= read -r pool_path; do
    [[ -n "$pool_path" ]] || continue
    canonical_source="$(readlink -f -- "$pool_path" 2>/dev/null || true)"
    if [[ -n "${disk_nodes[$canonical_source]:-}" ]]; then
      echo "❌ Selected disk belongs to an imported ZFS pool during ${stage}: ${pool_path}" >&2
      return 1
    fi
  done <<<"$pool_paths"
}

verify_installer_network() {
  local stage="$1"
  local duplicate_log

  if ! ip link show "$lan_iface" >/dev/null 2>&1; then
    echo "❌ Configured LAN interface is absent during ${stage}: ${lan_iface}" >&2
    return 1
  fi
  if [[ -r "/sys/class/net/${lan_iface}/carrier" \
    && "$(<"/sys/class/net/${lan_iface}/carrier")" != "1" ]]; then
    echo "❌ Configured LAN interface has no carrier during ${stage}: ${lan_iface}" >&2
    return 1
  fi
  if ! ip route get "$lan_gateway" oif "$lan_iface" >/dev/null 2>&1; then
    echo "❌ Installer has no route to configured gateway ${lan_gateway} through ${lan_iface} during ${stage}." >&2
    return 1
  fi
  if ! arping -q -c 2 -w 3 -I "$lan_iface" "$lan_gateway" >/dev/null 2>&1; then
    echo "❌ Configured LAN gateway ${lan_gateway} did not answer link-layer probes on ${lan_iface} during ${stage}." >&2
    return 1
  fi

  duplicate_log="$(mktemp)"
  # Probe even when the installer already owns the configured address: the
  # local kernel does not answer its own DAD probe, while a conflicting peer
  # will.
  if ! arping -D -q -c 2 -w 3 -I "$lan_iface" "$lan_ip" >"$duplicate_log" 2>&1; then
    echo "❌ Configured LAN address ${lan_ip} appears to be in use on ${lan_iface} during ${stage}; disks were not touched." >&2
    sed 's/^/   /' "$duplicate_log" >&2
    rm -f -- "$duplicate_log"
    return 1
  fi
  rm -f -- "$duplicate_log"
  echo "Verified installer LAN carrier, gateway, and address uniqueness during ${stage}."
}

for disk_id in "${configured_disks[@]}"; do
  if [[ -z "$disk_id" || "$disk_id" == *CHANGE_ME* || "$disk_id" == */* ]]; then
    echo "❌ Invalid configured by-id basename: $disk_id" >&2
    exit 1
  fi

  disk_path="/dev/disk/by-id/${disk_id}"
  if [[ ! -b "$disk_path" ]]; then
    echo "❌ Configured disk is not a block device on this machine: $disk_path" >&2
    exit 1
  fi

  canonical="$(readlink -f "$disk_path")"
  if [[ "$(lsblk -dnro TYPE "$canonical")" != "disk" ]]; then
    echo "❌ Configured ID does not resolve to a whole disk: $disk_path -> $canonical" >&2
    exit 1
  fi
  if [[ -n "${canonical_disks[$canonical]:-}" ]]; then
    echo "❌ ${disk_id} and ${canonical_disks[$canonical]} resolve to the same physical disk: $canonical" >&2
    exit 1
  fi
  canonical_disks[$canonical]="$disk_id"
  configured_canonical_by_id[$disk_id]="$canonical"
  disk_identity="$(lsblk -dn -o MAJ:MIN,SIZE,MODEL,SERIAL,WWN "$canonical")"
  if [[ -z "$disk_identity" ]]; then
    echo "❌ Could not capture a stable identity for configured disk: $disk_path" >&2
    exit 1
  fi
  configured_identity_by_id[$disk_id]="$disk_identity"

  assert_disk_is_idle "$disk_path" "$canonical" "initial review"
done

if ((system_disk_only == 1)); then
  if ((${#data_pool_disks[@]} == 0)); then
    echo "❌ System-disk-only recovery cannot prove a preserved pool with no configured member disks." >&2
    exit 1
  fi
  for disk_id in "${data_pool_disks[@]}"; do
    if [[ -z "$disk_id" || "$disk_id" == *CHANGE_ME* || "$disk_id" == */* ]]; then
      echo "❌ Invalid configured preserved-pool by-id basename: $disk_id" >&2
      exit 1
    fi
    disk_path="/dev/disk/by-id/${disk_id}"
    if [[ ! -b "$disk_path" ]]; then
      echo "❌ Cannot prove preserved-pool disk identity because this configured member is absent: $disk_path" >&2
      exit 1
    fi
    canonical="$(readlink -f -- "$disk_path")"
    if [[ "$(lsblk -dnro TYPE "$canonical")" != "disk" ]]; then
      echo "❌ Configured preserved-pool ID does not resolve to a whole disk: $disk_path -> $canonical" >&2
      exit 1
    fi
    if [[ -n "${canonical_disks[$canonical]:-}" ]]; then
      echo "❌ Refusing system-disk-only recovery: selected system disk ${canonical_disks[$canonical]} aliases preserved data-pool member ${disk_id} (${canonical})." >&2
      exit 1
    fi
    if [[ -n "${preserved_canonical_disks[$canonical]:-}" ]]; then
      echo "❌ Preserved data-pool IDs ${disk_id} and ${preserved_canonical_disks[$canonical]} resolve to the same physical disk: ${canonical}" >&2
      exit 1
    fi
    preserved_canonical_disks[$canonical]="$disk_id"
    preserved_canonical_by_id[$disk_id]="$canonical"
    disk_identity="$(lsblk -dn -o MAJ:MIN,SIZE,MODEL,SERIAL,WWN "$canonical")"
    if [[ -z "$disk_identity" ]]; then
      echo "❌ Could not capture a stable identity for preserved data-pool disk: $disk_path" >&2
      exit 1
    fi
    preserved_identity_by_id[$disk_id]="$disk_identity"
  done
fi

echo "Blank-disk bootstrap plan"
echo "  source:     $pinned_source_path"
echo "  host:       $host"
echo "  profile:    $storage_profile"
  echo "  disko host: ${host}${disko_configuration_suffix}"
if ((system_disk_only == 1)); then
  echo "  recovery:   SYSTEM DISK ONLY; configured data-pool disks are excluded"
  echo "  preserved data pool: ${data_pool_name} (pinned GUID ${expected_data_pool_guid})"
  for disk_id in "${data_pool_disks[@]}"; do
    printf '    - preserved: %s -> %s\n' \
      "$disk_id" "${preserved_canonical_by_id[$disk_id]}"
    printf '      identity: %s\n' "${preserved_identity_by_id[$disk_id]}"
  done
fi
echo "  disks that will be erased:"
for disk_id in "${configured_disks[@]}"; do
  canonical="$(readlink -f "/dev/disk/by-id/${disk_id}")"
  size="$(blockdev --getsize64 "$canonical")"
  printf '    - %s -> %s (%s bytes)\n' "$disk_id" "$canonical" "$size"
  printf '      identity: %s\n' "${configured_identity_by_id[$disk_id]}"
  wipefs --no-act "$canonical" | sed 's/^/      existing signature: /' || true
done

if ((apply == 0)); then
  echo
  echo "Read-only plan complete. Re-run with --apply, an exact --confirm-host,"
  echo "and one exact --confirm-disk argument for every listed disk."
  exit 0
fi

if [[ "$EUID" -ne 0 ]]; then
  echo "❌ Destructive disk bootstrap must run as root from the NixOS installer." >&2
  exit 1
fi
if [[ ! -d /sys/firmware/efi ]]; then
  echo "❌ This layout requires UEFI; reboot the installer in UEFI mode before applying." >&2
  exit 1
fi
verify_installer_network "initial pre-build validation"
if [[ "$confirmed_host" != "$host" ]]; then
  echo "❌ --confirm-host must exactly equal '$host'." >&2
  exit 1
fi
if ((system_disk_only == 1)) && [[ "$confirmed_preserved_pool" != "$data_pool_name" ]]; then
  echo "❌ --confirm-preserve-data-pool must exactly equal '${data_pool_name}' for system-disk-only recovery." >&2
  exit 1
elif ((system_disk_only == 0)) && [[ -n "$confirmed_preserved_pool" ]]; then
  echo "❌ --confirm-preserve-data-pool is valid only with --system-disk-only." >&2
  exit 1
fi

configured_set="$(printf '%s\n' "${configured_disks[@]}" | sort -u)"
confirmed_set="$(printf '%s\n' "${confirmed_disks[@]}" | sed '/^$/d' | sort -u)"
if [[ "$configured_set" != "$confirmed_set" || "${#confirmed_disks[@]}" -ne "${#configured_disks[@]}" ]]; then
  echo "❌ Confirm every configured disk exactly once with --confirm-disk." >&2
  echo "Configured:" >&2
  printf '  %s\n' "${configured_disks[@]}" >&2
  exit 1
fi

verify_age_recovery_copies() {
  local stage="$1"
  local distinct_filesystem_status identity_mount backup_mount backup_fstype
  local backup_disk_status expected_age_recipient

  if [[ -z "$identity_file" || -z "$age_key_backup" ]]; then
    echo "❌ Destructive bootstrap requires --identity and --age-key-backup so secret recovery does not depend on the disk being erased." >&2
    exit 1
  fi
  identity_file="$(readlink -f -- "$identity_file" 2>/dev/null || true)"
  age_key_backup="$(readlink -f -- "$age_key_backup" 2>/dev/null || true)"
  if [[ ! -f "$identity_file" || ! -r "$identity_file" || ! -f "$age_key_backup" || ! -r "$age_key_backup" ]]; then
    echo "❌ Both private age-key paths must be readable regular files during ${stage}." >&2
    exit 1
  fi
  if [[ "$(stat -c '%d:%i' -- "$identity_file")" == "$(stat -c '%d:%i' -- "$age_key_backup")" ]]; then
    echo "❌ --age-key-backup must be a distinct second file, not another path to --identity." >&2
    exit 1
  fi
  distinct_filesystem_status=0
  bootstrap_files_use_distinct_filesystems "$identity_file" "$age_key_backup" \
    || distinct_filesystem_status=$?
  if ((distinct_filesystem_status != 0)); then
    if ((distinct_filesystem_status == 2)); then
      echo "❌ Could not prove the two private age-key copies use distinct filesystems during ${stage}." >&2
    else
      echo "❌ --age-key-backup is on the same filesystem as --identity; bind mounts and second filenames do not qualify." >&2
    fi
    exit 1
  fi
  identity_mount="$(findmnt -n -o TARGET -T "$identity_file" 2>/dev/null || true)"
  backup_mount="$(findmnt -n -o TARGET -T "$age_key_backup" 2>/dev/null || true)"
  backup_fstype="$(findmnt -n -o FSTYPE -T "$age_key_backup" 2>/dev/null || true)"
  if [[ -z "$backup_mount" || "$backup_mount" == "/" || "$backup_mount" == "$identity_mount" \
    || "$backup_fstype" =~ ^(tmpfs|ramfs|rootfs|overlay|squashfs)$ ]]; then
    echo "❌ --age-key-backup must live on a separately mounted durable filesystem, distinct from --identity during ${stage}." >&2
    exit 1
  fi
  if bootstrap_backup_uses_selected_disk "$age_key_backup" "${!canonical_disks[@]}"; then
    echo "❌ --age-key-backup resides on a configured disk selected for erasure during ${stage}: ${age_key_backup}" >&2
    exit 1
  else
    backup_disk_status=$?
    if ((backup_disk_status == 2)); then
      echo "❌ Could not resolve the local block-device ancestry for --age-key-backup during ${stage}; refusing destructive bootstrap." >&2
      exit 1
    fi
  fi
  expected_age_recipient="$(tr -d '\r\n' <"$pinned_source_path/secrets/pubkeys/age.pub")"
  if [[ "$(age-keygen -y "$identity_file" 2>/dev/null | tr -d '\r\n')" != "$expected_age_recipient" ]]; then
    echo "❌ --identity does not match the pinned repository age recipient during ${stage}." >&2
    exit 1
  fi
  if [[ "$(age-keygen -y "$age_key_backup" 2>/dev/null | tr -d '\r\n')" != "$expected_age_recipient" ]]; then
    echo "❌ --age-key-backup does not match the pinned repository age recipient during ${stage}." >&2
    exit 1
  fi
  echo "Verified two matching private age-key copies on separate filesystems during ${stage}; no private material was printed."
}

verify_age_recovery_copies "pre-build validation"

bash "$pinned_source_path/scripts/helpers/verify-bootstrap-secrets.sh" \
  --repo-root "$pinned_source_path" \
  --identity "$identity_file" \
  --active-secret-names-json "$active_secret_names_json"

echo
echo "Building the complete pinned target system before touching disks..."
target_system="$(build_pinned_target_system "$host")"
if ! validate_pinned_target_system "$target_system"; then
  exit 1
fi
echo "Complete target closure: ${target_system}"

echo "Building the pinned disko plan before touching disks..."
disko_script="$(
  build_pinned_disko_plan "$host" "$disko_configuration_suffix"
)"
if ! validate_pinned_disko_plan "$disko_script"; then
  exit 1
fi

# The build can take time. Recheck that every confirmed by-id link still names
# the same unmounted whole disk before handing control to the immutable script.
verify_installer_network "post-build final validation"
for disk_id in "${configured_disks[@]}"; do
  disk_path="/dev/disk/by-id/${disk_id}"
  if [[ ! -b "$disk_path" ]]; then
    echo "❌ Confirmed disk disappeared while building the Disko plan: $disk_path" >&2
    exit 1
  fi
  canonical="$(readlink -f "$disk_path")"
  if [[ "$canonical" != "${configured_canonical_by_id[$disk_id]}" ]] \
    || [[ "$(lsblk -dnro TYPE "$canonical")" != "disk" ]]; then
    echo "❌ Confirmed disk identity changed while building the Disko plan: $disk_path" >&2
    exit 1
  fi
  disk_identity="$(lsblk -dn -o MAJ:MIN,SIZE,MODEL,SERIAL,WWN "$canonical")"
  if [[ "$disk_identity" != "${configured_identity_by_id[$disk_id]}" ]]; then
    echo "❌ Confirmed disk hardware fingerprint changed while building the Disko plan: $disk_path" >&2
    exit 1
  fi
  assert_disk_is_idle "$disk_path" "$canonical" "post-build recheck"
done

if ((system_disk_only == 1)); then
  for disk_id in "${data_pool_disks[@]}"; do
    disk_path="/dev/disk/by-id/${disk_id}"
    if [[ ! -b "$disk_path" ]]; then
      echo "❌ Preserved data-pool disk disappeared while building the Disko plan: $disk_path" >&2
      exit 1
    fi
    canonical="$(readlink -f -- "$disk_path")"
    if [[ "$canonical" != "${preserved_canonical_by_id[$disk_id]}" ]] \
      || [[ "$(lsblk -dnro TYPE "$canonical")" != "disk" ]] \
      || [[ -n "${canonical_disks[$canonical]:-}" ]]; then
      echo "❌ Preserved data-pool disk identity changed or now aliases the selected system disk: $disk_path" >&2
      exit 1
    fi
    disk_identity="$(lsblk -dn -o MAJ:MIN,SIZE,MODEL,SERIAL,WWN "$canonical")"
    if [[ "$disk_identity" != "${preserved_identity_by_id[$disk_id]}" ]]; then
      echo "❌ Preserved data-pool disk hardware fingerprint changed while building the Disko plan: $disk_path" >&2
      exit 1
    fi
  done
fi

# The long closure and Disko builds create a physical-media TOCTOU window. Do
# not erase anything unless both recovery copies still independently pass every
# durability, device-ancestry, and recipient check immediately before exec.
verify_age_recovery_copies "post-build recheck"

echo "Applying the reviewed disko plan. This is irreversible."
exec "$disko_script"
