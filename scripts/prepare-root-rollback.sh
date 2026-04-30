#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/prepare-root-rollback.sh [--dry-run]

Prepare the Btrfs root layout for repo.impermanence.enableRootRollback by
creating the writable /root subvolume and the read-only /root-blank snapshot
from the current live system root.
EOF
}

dry_run=false
case "${1:-}" in
  "")
    ;;
  --dry-run)
    dry_run=true
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

need nix jq mountpoint rsync mktemp findmnt

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

config_json="$(
  nix_json '{
    rootDevice = "/dev/disk/by-id/${vars.mainDisk}-part2";
    rootSubvolume = cfg.repo.impermanence.rootSubvolume;
    blankSnapshot = cfg.repo.impermanence.blankSnapshot;
    markerRoot = "/persist/appdata/.nixos-managed/root-rollback-prep-v1";
  }'
)"

root_device="$(jq -r '.rootDevice' <<<"$config_json")"
root_subvolume="$(jq -r '.rootSubvolume' <<<"$config_json")"
blank_snapshot="$(jq -r '.blankSnapshot' <<<"$config_json")"
marker_root="$(jq -r '.markerRoot' <<<"$config_json")"
marker_file="${marker_root}/last-run"

top_level_mount="$(mktemp -d)"
trap 'if mountpoint -q "$top_level_mount"; then "${sudo_cmd[@]}" umount "$top_level_mount"; fi; rm -rf "$top_level_mount"' EXIT

current_root_opts="$(findmnt -no OPTIONS / 2>/dev/null || true)"
echo "Preparing root rollback layout on ${root_device}"
echo "Current / mount options: ${current_root_opts:-unknown}"
echo "Target subvolume: ${root_subvolume}"
echo "Blank snapshot: ${blank_snapshot}"

"${sudo_cmd[@]}" mount -t btrfs -o subvolid=5 "$root_device" "$top_level_mount"

if [[ -d "${top_level_mount}/${root_subvolume}" && -d "${top_level_mount}/${blank_snapshot}" ]]; then
  echo "Root rollback layout already prepared."
  exit 0
fi

if $dry_run; then
  echo "Would create ${top_level_mount}/${root_subvolume}"
  echo "Would rsync live / into ${top_level_mount}/${root_subvolume}"
  echo "Would create read-only snapshot ${top_level_mount}/${blank_snapshot}"
  exit 0
fi

"${sudo_cmd[@]}" install -d -m 0755 "$marker_root"

if [[ ! -d "${top_level_mount}/${root_subvolume}" ]]; then
  "${sudo_cmd[@]}" btrfs subvolume create "${top_level_mount}/${root_subvolume}"
fi

"${sudo_cmd[@]}" rsync -aHAXx --delete \
  --exclude='/boot/' \
  --exclude='/dev/' \
  --exclude='/mnt/' \
  --exclude='/nix/' \
  --exclude='/persist/' \
  --exclude='/proc/' \
  --exclude='/run/' \
  --exclude='/sys/' \
  --exclude='/tmp/' \
  / "${top_level_mount}/${root_subvolume}/"

"${sudo_cmd[@]}" install -d -m 0755 \
  "${top_level_mount}/${root_subvolume}/boot" \
  "${top_level_mount}/${root_subvolume}/dev" \
  "${top_level_mount}/${root_subvolume}/mnt" \
  "${top_level_mount}/${root_subvolume}/nix" \
  "${top_level_mount}/${root_subvolume}/persist" \
  "${top_level_mount}/${root_subvolume}/proc" \
  "${top_level_mount}/${root_subvolume}/run" \
  "${top_level_mount}/${root_subvolume}/sys" \
  "${top_level_mount}/${root_subvolume}/tmp"

if [[ -d "${top_level_mount}/${blank_snapshot}" ]]; then
  "${sudo_cmd[@]}" btrfs subvolume delete "${top_level_mount}/${blank_snapshot}"
fi
"${sudo_cmd[@]}" btrfs subvolume snapshot -r \
  "${top_level_mount}/${root_subvolume}" \
  "${top_level_mount}/${blank_snapshot}"

date --utc +%Y%m%dT%H%M%SZ | "${sudo_cmd[@]}" tee "$marker_file" >/dev/null
echo "✅ Root rollback layout prepared."
