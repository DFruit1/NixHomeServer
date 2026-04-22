#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

nix_json() {
  local expr="$1"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake (toString ${repo_root});
      vars = import ${repo_root}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
    in
      ${expr}
  "
}

usage() {
  cat <<'EOF'
Usage: scripts/cold-storage.sh <status|mount|unmount> [pool-name]

Operate only on the manual cold-storage pools declared in vars.coldStoragePools.
This helper does not create or destroy pools.

Examples:
  scripts/cold-storage.sh status
  scripts/cold-storage.sh mount cold-v1jan8ph
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

need nix jq findmnt mountpoint install zpool zfs

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi

pools_json="$(
  nix_json '
    map (pool: {
      name = pool.name;
      disk = pool.disk;
      mountPoint = pool.mountPoint;
      device = "/dev/disk/by-id/${pool.disk}";
    }) vars.coldStoragePools
  '
)"

if [[ "$(jq 'length' <<<"$pools_json")" -eq 0 ]]; then
  echo "❌ No cold-storage pools are configured." >&2
  exit 1
fi

resolve_pool() {
  local requested="${1:-}"

  if [[ -z "$requested" ]]; then
    if [[ "$(jq 'length' <<<"$pools_json")" -eq 1 ]]; then
      jq '.[0]' <<<"$pools_json"
      return
    fi

    echo "❌ Pool name is required when multiple cold-storage pools are configured." >&2
    jq -r '.[] | "- \(.name)"' <<<"$pools_json" >&2
    exit 1
  fi

  local selected
  selected="$(jq -e --arg requested "$requested" '.[] | select(.name == $requested)' <<<"$pools_json" || true)"
  if [[ -z "$selected" ]]; then
    echo "❌ Unknown cold-storage pool: ${requested}" >&2
    jq -r '.[] | "- \(.name)"' <<<"$pools_json" >&2
    exit 1
  fi

  printf '%s\n' "$selected"
}

status_pool() {
  local pool_json="$1"
  local name device mountpoint_path imported source fstype

  name="$(jq -r '.name' <<<"$pool_json")"
  device="$(jq -r '.device' <<<"$pool_json")"
  mountpoint_path="$(jq -r '.mountPoint' <<<"$pool_json")"

  echo "pool: ${name}"
  echo "device: ${device}"
  echo "mountpoint: ${mountpoint_path}"

  if "${sudo_cmd[@]}" zpool list -H -o name "$name" >/dev/null 2>&1; then
    imported=true
  else
    imported=false
  fi
  echo "imported: ${imported}"

  source="$(findmnt -rn -o SOURCE --target "$mountpoint_path" 2>/dev/null || true)"
  fstype="$(findmnt -rn -o FSTYPE --target "$mountpoint_path" 2>/dev/null || true)"

  if [[ "$source" == "$name" && "$fstype" == "zfs" ]]; then
    echo "status: mounted ${source} ${fstype}"
  else
    echo "status: unmounted"
  fi
}

mount_pool() {
  local pool_json="$1"
  local name device mountpoint_path

  name="$(jq -r '.name' <<<"$pool_json")"
  device="$(jq -r '.device' <<<"$pool_json")"
  mountpoint_path="$(jq -r '.mountPoint' <<<"$pool_json")"

  if [[ ! -e "$device" ]]; then
    echo "❌ Cold-storage device not found: ${device}" >&2
    exit 1
  fi

  "${sudo_cmd[@]}" install -d -m 0750 "$mountpoint_path"

  if ! "${sudo_cmd[@]}" zpool list -H -o name "$name" >/dev/null 2>&1; then
    "${sudo_cmd[@]}" zpool import -N -d /dev/disk/by-id "$name"
  fi

  if ! findmnt -rn --target "$mountpoint_path" >/dev/null 2>&1; then
    "${sudo_cmd[@]}" zfs mount "$name"
  fi

  status_pool "$pool_json"
}

unmount_pool() {
  local pool_json="$1"
  local name mountpoint_path

  name="$(jq -r '.name' <<<"$pool_json")"
  mountpoint_path="$(jq -r '.mountPoint' <<<"$pool_json")"

  if findmnt -rn --target "$mountpoint_path" >/dev/null 2>&1; then
    "${sudo_cmd[@]}" zfs unmount "$name"
  fi

  if "${sudo_cmd[@]}" zpool list -H -o name "$name" >/dev/null 2>&1; then
    "${sudo_cmd[@]}" zpool export "$name"
  fi

  status_pool "$pool_json"
}

case "${1:-}" in
  status)
    if [[ $# -gt 1 ]]; then
      status_pool "$(resolve_pool "${2:-}")"
    else
      while IFS= read -r pool_json; do
        [[ -n "$pool_json" ]] || continue
        status_pool "$pool_json"
        echo
      done < <(jq -c '.[]' <<<"$pools_json")
    fi
    ;;
  mount)
    mount_pool "$(resolve_pool "${2:-}")"
    ;;
  unmount)
    unmount_pool "$(resolve_pool "${2:-}")"
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
