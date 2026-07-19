#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
source "$script_dir/helpers/deploy-command.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [--target <user@host>] [--build-host <user@host>] [--build-locally] [--action test|switch] [--hostname <flake-hostname>] [--debug]

Stage the current repo and run a NixOS rebuild.

By default, the target is vars.localAdminUser@vars.serverLanIP and the target host
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
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --target requires user@host" >&2; exit 1; }
      target_host="${2:-}"
      shift 2
      ;;
    --build-host)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --build-host requires user@host" >&2; exit 1; }
      build_host="${2:-}"
      shift 2
      ;;
    --build-locally)
      build_locally=true
      shift
      ;;
    --action)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --action requires test or switch" >&2; exit 1; }
      action="${2:-}"
      shift 2
      ;;
    --hostname)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --hostname requires a flake hostname" >&2; exit 1; }
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
if [[ ! "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
  echo "blocked: --hostname must be one DNS hostname label" >&2
  exit 1
fi

if [[ -z "$target_host" ]]; then
  local_admin_user="$(nix_flake_var 'if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser')"
  target_address="$(nix_flake_var 'vars.serverLanIP')"
  target_host="${local_admin_user}@${target_address}"
fi

if [[ "$build_locally" != "true" && -z "$build_host" ]]; then
  build_host="$target_host"
fi

print_quoted_command() {
  local command=("$@")
  printf '%q' "${command[0]}"
  printf ' %q' "${command[@]:1}"
  printf '\n'
}

if [[ "${DEPLOY_DRY_RUN:-}" == "1" ]]; then
  dry_run_rebuild_command=()
  build_nixos_rebuild_command dry_run_rebuild_command \
    "$action" "$hostname" "$build_locally" "$target_host" "$build_host"

  echo "mode=$([[ "$build_locally" == "true" ]] && echo local || echo remote)"
  echo "target_host=${target_host}"
  echo "build_host=$([[ "$build_locally" == "true" ]] && echo local || echo "$build_host")"
  echo "hostname=${hostname}"
  echo "action=${action}"
  echo "debug=${debug}"
  echo -n "rebuild_command="
  print_quoted_command "${dry_run_rebuild_command[@]}"
  if [[ "$action" == "switch" ]]; then
    echo "activation_command=detached switch-to-configuration switch"
  fi
  exit 0
fi

need ssh tar

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

  TARGET_HOST="$target_host" \
    BUILD_HOST="local" \
    ACTION="$action" \
    HOSTNAME_ARG="$hostname" \
    DEBUG_MODE="$debug" \
    BUILD_LOCALLY="$build_locally" \
    bash ./scripts/helpers/deploy-executor.sh
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
  "BUILD_LOCALLY=false"
)
remote_command="$(printf '%s ' "${remote_env[@]}")bash -s"

ssh -T "$build_host" "$remote_command" <<'EOF'
set -euo pipefail

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
cd "$tmpdir"

bash ./scripts/helpers/deploy-executor.sh
EOF

echo "Deploy ${action} completed."
