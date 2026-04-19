#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
source "$repo_root/scripts/lib-storage-health.sh"

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}"

need() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "❌ Missing required tool: $tool" >&2
      exit 1
    fi
  done
}

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

need nix jq smartctl journalctl

mode="strict"
collect_dir=""
start_long_tests=0

while (($# > 0)); do
  case "$1" in
    --mode)
      mode="$2"
      shift 2
      ;;
    --collect-dir)
      collect_dir="$2"
      shift 2
      ;;
    --start-long-tests)
      start_long_tests=1
      shift
      ;;
    --help|-h)
      cat <<'EOF'
Usage: scripts/storage-preflight.sh [--mode warn|strict] [--collect-dir <dir>] [--start-long-tests]

Runs the shared SMART health policy against the currently configured protected array
from vars.nix. Use --collect-dir to capture smartctl -x output per disk and
--start-long-tests to launch long self-tests before a later re-check.
EOF
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

sudo_cmd=()
if (( EUID != 0 )); then
  sudo_cmd=(sudo)
fi
storage_health_cmd_prefix=("${sudo_cmd[@]}")

mapfile -t labels < <(
  nix_json '
    let
      dataLabels = builtins.genList (idx: "disk${toString (idx + 1)}") (builtins.length vars.dataDisks);
      parityLabels = builtins.genList (idx: if idx == 0 then "parity" else "parity${toString (idx + 1)}") (builtins.length vars.parityDisks);
    in
      dataLabels ++ parityLabels
  ' | jq -r '.[]'
)
mapfile -t devices < <(
  nix_json '
    map (diskId: "/dev/disk/by-id/${diskId}") (vars.dataDisks ++ vars.parityDisks)
  ' | jq -r '.[]'
)

if ((${#devices[@]} == 0)); then
  echo "❌ No protected-array disks are configured in vars.nix." >&2
  exit 1
fi

specs=()
for idx in "${!devices[@]}"; do
  specs+=("${labels[$idx]}=${devices[$idx]}")
done

if [[ -n "$collect_dir" ]]; then
  mkdir -p "$collect_dir"
  echo "Collecting smartctl -x output in $collect_dir"
  for idx in "${!devices[@]}"; do
    echo "  ${labels[$idx]} -> ${devices[$idx]}"
    storage_health_run_command smartctl -d sat -x "${devices[$idx]}" >"${collect_dir}/${labels[$idx]}.smartctl"
  done
fi

if (( start_long_tests != 0 )); then
  echo "Starting long SMART self-tests on configured protected-array disks"
  for idx in "${!devices[@]}"; do
    echo "  ${labels[$idx]} -> ${devices[$idx]}"
    storage_health_run_command smartctl -d sat -t long "${devices[$idx]}"
  done
  echo "Re-run this script after the long tests complete to enforce the strict gate on the latest SMART data."
fi

echo "Running ${mode} SMART gate for configured protected-array disks"
storage_health_check "$mode" "${specs[@]}"
