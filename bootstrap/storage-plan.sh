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
echo "  system disk: $(jq -r '.mainDisk' <<<"$settings_json")"
echo "  data pool:   $(jq -r '.zfsDataPool.name' <<<"$settings_json") at $(jq -r '.zfsDataPool.mountPoint' <<<"$settings_json")"
echo "  data disks:"
jq -r '.zfsDataPoolDiskIds[] | "    - " + .' <<<"$settings_json"

echo
cat <<'EOF'
vars.nix storage snippet template:

  mainDisk = "<system-disk-by-id-basename>";
  zfsDataPool = {
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
    ];
  };

This command is read-only. Use disko only for blank-machine bootstrap.
EOF
