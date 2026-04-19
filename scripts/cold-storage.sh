#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

nix_var() {
  local expr="$1"
  nix eval --raw --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

usage() {
  cat <<'EOF'
Usage: scripts/cold-storage.sh <status|mount|unmount>
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

need nix findmnt mountpoint mount umount install

disk_id="$(nix_var 'vars.coldStorageDisk')"
mountpoint_path="$(nix_var 'vars.coldStorageMountPoint')"
partition="/dev/disk/by-id/${disk_id}-part1"

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

status_cmd() {
  echo "disk: ${disk_id}"
  echo "partition: ${partition}"
  echo "mountpoint: ${mountpoint_path}"

  if findmnt -rn "$mountpoint_path" >/dev/null 2>&1; then
    findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS "$mountpoint_path" | sed 's/^/status: mounted /'
  else
    echo "status: unmounted"
  fi
}

mount_cmd() {
  if [[ ! -e "$partition" ]]; then
    echo "❌ Cold-storage partition not found: ${partition}" >&2
    exit 1
  fi

  "${sudo_cmd[@]}" install -d -m 0750 "$mountpoint_path"

  if mountpoint -q "$mountpoint_path"; then
    echo "ℹ️ Cold storage already mounted at ${mountpoint_path}"
    status_cmd
    return
  fi

  "${sudo_cmd[@]}" mount -o rw "$partition" "$mountpoint_path"
  status_cmd
}

unmount_cmd() {
  if ! mountpoint -q "$mountpoint_path"; then
    echo "ℹ️ Cold storage already unmounted at ${mountpoint_path}"
    status_cmd
    return
  fi

  "${sudo_cmd[@]}" umount "$mountpoint_path"
  status_cmd
}

case "${1:-}" in
  status)
    status_cmd
    ;;
  mount)
    mount_cmd
    ;;
  unmount)
    unmount_cmd
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
