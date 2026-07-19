#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/admin/common.sh"
source "$repo_root/scripts/helpers/bootstrap-source-snapshot.sh"

usage() {
  cat <<'EOF'
Usage:
  bootstrap/apply-disko.sh [--host <flake-hostname>]
  bootstrap/apply-disko.sh --host <flake-hostname> --apply \
    --confirm-host <flake-hostname> --confirm-disk <by-id-basename> [--confirm-disk ...]

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

need awk blockdev jq lsblk nix readlink sed sort uniq wipefs
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
configured_host="$(jq -r '.hostname' <<<"$settings_json")"
storage_profile="$(jq -r '.storageProfile' <<<"$settings_json")"
mapfile -t configured_disks < <(jq -r '[.mainDisk] + (if .storageProfile == "zfs-mirror" then .zfsDataPoolDiskIds else [] end) | .[]' <<<"$settings_json")

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

declare -A canonical_disks=()
declare -A configured_canonical_by_id=()
declare -A configured_identity_by_id=()
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

  mounted="$(lsblk -nrpo MOUNTPOINTS "$canonical" | awk 'NF { print; exit }')"
  if [[ -n "$mounted" ]]; then
    echo "❌ Selected disk or one of its partitions is mounted ($mounted): $disk_path" >&2
    exit 1
  fi
done

echo "Blank-disk bootstrap plan"
echo "  source:     $pinned_source_path"
echo "  host:       $host"
echo "  profile:    $storage_profile"
echo "  disko host: ${host}-bootstrap"
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
if [[ "$confirmed_host" != "$host" ]]; then
  echo "❌ --confirm-host must exactly equal '$host'." >&2
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

echo
echo "Building the pinned disko plan before touching disks..."
disko_script="$(
  build_pinned_disko_plan "$host"
)"
if ! validate_pinned_disko_plan "$disko_script"; then
  exit 1
fi

# The build can take time. Recheck that every confirmed by-id link still names
# the same unmounted whole disk before handing control to the immutable script.
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
  mounted="$(lsblk -nrpo MOUNTPOINTS "$canonical" | awk 'NF { print; exit }')"
  if [[ -n "$mounted" ]]; then
    echo "❌ Confirmed disk became mounted while building the Disko plan ($mounted): $disk_path" >&2
    exit 1
  fi
done

echo "Applying the reviewed disko plan. This is irreversible."
exec "$disko_script"
