#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/admin/common.sh"

usage() {
  cat <<'EOF'
Usage: bootstrap/storage-plan.sh [--host <flake-hostname>]

Print a non-destructive disk inventory and vars.nix storage snippet for
blank-machine bootstrap planning.
EOF
}

host=""
while (($# > 0)); do
  case "$1" in
    --host)
      host="${2:-}"
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

if [[ -z "$host" ]]; then
  host="$(default_host)"
fi

need jq lsblk
if ((status_blocked > 0)); then
  finish_report
fi

settings_json="$(nix_json_for_host "$host" "removeAttrs flake.lib.nixhomeserverSettings.${host} [ \"kanidmIssuer\" \"kanidmDiscoveryUrl\" ]")"

echo "Storage inventory"
echo
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS

echo
echo "Preferred by-id candidates"
echo
if [[ -d /dev/disk/by-id ]]; then
  find /dev/disk/by-id -maxdepth 1 -type l \
    ! -name '*-part*' \
    ! -name 'wwn-*' \
    -printf '%f -> %l\n' | sort
else
  echo "warning: /dev/disk/by-id is not available on this machine"
fi

echo
echo "Current settings"
echo "  platform:    $(jq -r '.hostPlatform' <<<"$settings_json")"
echo "  storage:     $(jq -r '.storageProfile' <<<"$settings_json")"
echo "  system disk: $(jq -r '.mainDisk' <<<"$settings_json")"
if [[ "$(jq -r '.storageProfile' <<<"$settings_json")" == "zfs-mirror" ]]; then
  echo "  data pool:   $(jq -r '.zfsDataPool.name' <<<"$settings_json") at $(jq -r '.zfsDataPool.mountPoint' <<<"$settings_json")"
  echo "  data disks:"
  jq -r '.zfsDataPoolDiskIds[] | "    - " + .' <<<"$settings_json"
else
  echo "  data pool:   none"
  echo "  data disks:  none"
fi

echo
if [[ "$(jq -r '.storageProfile' <<<"$settings_json")" == "single-disk-ext4" ]]; then
  cat <<'EOF'
vars.nix single-disk storage snippet template:

  system = {
    hostPlatform = "aarch64-linux"; # or "x86_64-linux"
    hardwareProfile = "generic-uefi";
    timeZone = "Etc/UTC";
    hostId = "<stable-8-hex-character-host-id>";
  };

  storage = {
    profile = "single-disk-ext4";
    systemDisk = "<system-disk-by-id-basename>";
  };
EOF
else
  cat <<'EOF'
vars.nix ZFS mirror storage snippet template:

  storage = {
    profile = "zfs-mirror";
    systemDisk = "<system-disk-by-id-basename>";
    dataPool = {
      name = "data";
      mountPoint = "/mnt/data";
      mirrorPairs = [
        [
          "<first-data-disk-by-id-basename>"
          "<second-data-disk-by-id-basename>"
        ]
      ];
      datasets = [
        "users"
        "shared"
        "backups"
      ];
    };
  };
EOF
fi

cat <<'EOF'
This command is read-only. Use disko only for blank-machine bootstrap.
EOF
