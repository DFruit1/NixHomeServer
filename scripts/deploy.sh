#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [--target <user@host>] [--build-host <user@host>] [--build-locally] [--action test|switch] [--hostname <flake-hostname>] [--debug]

Stage the current repo and run a NixOS rebuild.

By default, the target is vars.localAdminUser@vars.hostname and the target host
also performs the build. Use --build-locally to build on this workstation and
activate the default target over SSH.

Fast mode performs only high-value checks: host evaluation, remote free-space
checks, nixos-rebuild, and failed-unit inspection.

Debug mode adds the full repository validation gate before the rebuild and
prints extra systemd/journal context if failed units remain afterward.
EOF
}

target_host=""
build_host=""
build_locally=false
action="test"
hostname=""
debug=false
repo_archive=""
local_tmpdir=""

while (($# > 0)); do
  case "$1" in
    --target)
      target_host="${2:-}"
      shift 2
      ;;
    --build-host)
      build_host="${2:-}"
      shift 2
      ;;
    --build-locally)
      build_locally=true
      shift
      ;;
    --action)
      action="${2:-}"
      shift 2
      ;;
    --hostname)
      hostname="${2:-}"
      shift 2
      ;;
    --debug)
      debug=true
      shift
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

if [[ "$action" != "test" && "$action" != "switch" ]]; then
  echo "blocked: --action must be test or switch" >&2
  exit 1
fi

if [[ "$build_locally" == "true" && -n "$build_host" ]]; then
  echo "blocked: --build-locally cannot be combined with --build-host" >&2
  exit 1
fi

need nix

if [[ -z "$hostname" ]]; then
  hostname="$(nix_flake_var 'vars.hostname')"
fi

if [[ -z "$target_host" ]]; then
  local_admin_user="$(nix_flake_var 'if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser')"
  target_host="${local_admin_user}@${hostname}"
fi

if [[ "$build_locally" != "true" && -z "$build_host" ]]; then
  build_host="$target_host"
fi

make_rebuild_command() {
  local -n out_cmd="$1"

  out_cmd=(nix run nixpkgs#nixos-rebuild -- "$action" --flake ".#${hostname}" --sudo)

  if [[ "$build_locally" == "true" ]]; then
    out_cmd+=(--target-host "$target_host")
  elif [[ "$target_host" != "$build_host" ]]; then
    out_cmd+=(--target-host "$target_host")
  fi
}

print_quoted_command() {
  local command=("$@")
  printf '%q' "${command[0]}"
  printf ' %q' "${command[@]:1}"
  printf '\n'
}

if [[ "${DEPLOY_DRY_RUN:-}" == "1" ]]; then
  dry_run_rebuild_command=()
  make_rebuild_command dry_run_rebuild_command

  echo "mode=$([[ "$build_locally" == "true" ]] && echo local || echo remote)"
  echo "target_host=${target_host}"
  echo "build_host=$([[ "$build_locally" == "true" ]] && echo local || echo "$build_host")"
  echo "hostname=${hostname}"
  echo "action=${action}"
  echo "debug=${debug}"
  echo -n "rebuild_command="
  print_quoted_command "${dry_run_rebuild_command[@]}"
  exit 0
fi

need ssh tar
if [[ "$build_locally" != "true" ]]; then
  need scp
fi

min_build_host_free_bytes=$((10 * 1024 * 1024 * 1024))
min_tmp_free_bytes=$((1 * 1024 * 1024 * 1024))

human_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
}

check_free_space() {
  local sandbox_build_dir build_backing_path build_available_bytes tmp_available_bytes

  sandbox_build_dir="$(nix config show 2>/dev/null | sed -n 's/^sandbox-build-dir = //p' | head -n 1)"
  if [[ -z "$sandbox_build_dir" ]]; then
    sandbox_build_dir="/build"
  fi

  build_backing_path="$sandbox_build_dir"
  while [[ ! -e "$build_backing_path" && "$build_backing_path" != "/" ]]; do
    build_backing_path="$(dirname "$build_backing_path")"
  done

  build_available_bytes="$(df -B1 --output=avail "$build_backing_path" | awk 'NR==2 { print $1 }')"
  tmp_available_bytes="$(df -B1 --output=avail /tmp | awk 'NR==2 { print $1 }')"

  echo "build space: ${build_backing_path} $(human_bytes "$build_available_bytes"), /tmp $(human_bytes "$tmp_available_bytes")"

  if (( build_available_bytes < min_build_host_free_bytes )); then
    echo "blocked: build host has insufficient Nix build space" >&2
    exit 1
  fi

  if (( tmp_available_bytes < min_tmp_free_bytes )); then
    echo "blocked: build host has insufficient /tmp space" >&2
    exit 1
  fi
}

check_failed_units() {
  local failed_units

  if [[ "$build_locally" != "true" && "$target_host" == "$build_host" ]]; then
    sudo systemctl --failed --no-pager
    failed_units="$(sudo systemctl --failed --no-legend --plain | awk '{ print $1 }' || true)"
  else
    ssh "$target_host" "sudo systemctl --failed --no-pager"
    failed_units="$(ssh "$target_host" "sudo systemctl --failed --no-legend --plain | awk '{ print \$1 }'" || true)"
  fi

  if [[ -n "$failed_units" ]]; then
    if [[ "$debug" == "true" ]]; then
      if [[ "$build_locally" != "true" && "$target_host" == "$build_host" ]]; then
        sudo systemctl status --no-pager $failed_units || true
        sudo journalctl -p warning..alert -n 200 --no-pager || true
      else
        ssh "$target_host" "sudo systemctl status --no-pager $failed_units || true; sudo journalctl -p warning..alert -n 200 --no-pager || true"
      fi
    fi
    echo "blocked: failed systemd units detected" >&2
    exit 1
  fi
}

cleanup_local_archive() {
  if [[ -n "$repo_archive" && -f "$repo_archive" ]]; then
    rm -f "$repo_archive"
  fi
  if [[ -n "$local_tmpdir" && -d "$local_tmpdir" ]]; then
    rm -rf "$local_tmpdir"
  fi
}

trap cleanup_local_archive EXIT

repo_archive="$(mktemp /tmp/nixhomeserver-deploy.XXXXXX.tar)"
create_deploy_repo_archive "$repo_archive"

if [[ "$build_locally" == "true" ]]; then
  local_tmpdir="$(mktemp -d)"
  tar -C "$local_tmpdir" -xf "$repo_archive"
  cd "$local_tmpdir"

  check_free_space

  echo "evaluating host ${hostname}"
  nix eval --raw ".#nixosConfigurations.${hostname}.config.system.build.toplevel.drvPath" >/dev/null

  if [[ "$debug" == "true" ]]; then
    echo "running debug validation"
    ./scripts/validate-repo.sh --full
  fi

  cmd=()
  make_rebuild_command cmd

  echo "running nixos-rebuild ${action}"
  "${cmd[@]}"

  echo "checking failed units"
  check_failed_units
  echo "Deploy ${action} completed."
  exit 0
fi

remote_archive="$(stage_archive_on_remote "$repo_archive" "$build_host" "nixhomeserver-deploy")"

remote_env=(
  "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive")"
  "TARGET_HOST=$(printf '%q' "$target_host")"
  "BUILD_HOST=$(printf '%q' "$build_host")"
  "ACTION=$(printf '%q' "$action")"
  "HOSTNAME_ARG=$(printf '%q' "$hostname")"
  "DEBUG_MODE=$(printf '%q' "$debug")"
)
remote_command="$(printf '%s ' "${remote_env[@]}")bash -s"

ssh -T "$build_host" "$remote_command" <<'EOF'
set -euo pipefail

export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes
accept-flake-config = true}"

min_build_host_free_bytes=$((10 * 1024 * 1024 * 1024))
min_tmp_free_bytes=$((1 * 1024 * 1024 * 1024))

human_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
}

check_free_space() {
  local sandbox_build_dir build_backing_path build_available_bytes tmp_available_bytes

  sandbox_build_dir="$(nix config show 2>/dev/null | sed -n 's/^sandbox-build-dir = //p' | head -n 1)"
  if [[ -z "$sandbox_build_dir" ]]; then
    sandbox_build_dir="/build"
  fi

  build_backing_path="$sandbox_build_dir"
  while [[ ! -e "$build_backing_path" && "$build_backing_path" != "/" ]]; do
    build_backing_path="$(dirname "$build_backing_path")"
  done

  build_available_bytes="$(df -B1 --output=avail "$build_backing_path" | awk 'NR==2 { print $1 }')"
  tmp_available_bytes="$(df -B1 --output=avail /tmp | awk 'NR==2 { print $1 }')"

  echo "build space: ${build_backing_path} $(human_bytes "$build_available_bytes"), /tmp $(human_bytes "$tmp_available_bytes")"

  if (( build_available_bytes < min_build_host_free_bytes )); then
    echo "blocked: build host has insufficient Nix build space" >&2
    exit 1
  fi

  if (( tmp_available_bytes < min_tmp_free_bytes )); then
    echo "blocked: build host has insufficient /tmp space" >&2
    exit 1
  fi
}

check_failed_units() {
  local failed_units

  if [[ "$TARGET_HOST" == "$BUILD_HOST" ]]; then
    sudo systemctl --failed --no-pager
    failed_units="$(sudo systemctl --failed --no-legend --plain | awk '{ print $1 }' || true)"
  else
    ssh "$TARGET_HOST" "sudo systemctl --failed --no-pager"
    failed_units="$(ssh "$TARGET_HOST" "sudo systemctl --failed --no-legend --plain | awk '{ print \$1 }'" || true)"
  fi

  if [[ -n "$failed_units" ]]; then
    if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
      if [[ "$TARGET_HOST" == "$BUILD_HOST" ]]; then
        sudo systemctl status --no-pager $failed_units || true
        sudo journalctl -p warning..alert -n 200 --no-pager || true
      else
        ssh "$TARGET_HOST" "sudo systemctl status --no-pager $failed_units || true; sudo journalctl -p warning..alert -n 200 --no-pager || true"
      fi
    fi
    echo "blocked: failed systemd units detected" >&2
    exit 1
  fi
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
cd "$tmpdir"

check_free_space

echo "evaluating host ${HOSTNAME_ARG}"
nix eval --raw ".#nixosConfigurations.${HOSTNAME_ARG}.config.system.build.toplevel.drvPath" >/dev/null

if [[ "${DEBUG_MODE:-false}" == "true" ]]; then
  echo "running debug validation"
  ./scripts/validate-repo.sh --full
fi

cmd=(nix run nixpkgs#nixos-rebuild -- "$ACTION" --flake ".#${HOSTNAME_ARG}" --sudo)
if [[ "$TARGET_HOST" != "$BUILD_HOST" ]]; then
  cmd+=(--target-host "$TARGET_HOST")
fi

echo "running nixos-rebuild ${ACTION}"
"${cmd[@]}"

echo "checking failed units"
check_failed_units
EOF

echo "Deploy ${action} completed."
