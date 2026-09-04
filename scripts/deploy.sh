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
Usage: scripts/deploy.sh [--target <user@host>] [--build-mode local|remote|balanced|maximum-effort] [--build-host <user@host>] [--build-locally] [--action test|switch] [--hostname <flake-hostname>] [--debug]

Stage the current repo and run a NixOS rebuild.

Run this helper from a Git checkout. Copied directories and source ZIPs are
rejected because they do not provide a safe tracked-file deployment manifest.

By default, the target is vars.localAdminUser@vars.serverLanIP and the build
allocation comes from vars.system.buildMode. Local and remote use all available
slots on one machine, balanced uses two slots on each, and maximum-effort uses
all available slots on both. --build-mode overrides the configured mode for one invocation.
--build-locally remains an alias for --build-mode local.

Fast mode performs high-value checks: host evaluation, build and target
free-space checks, a live test activation, failed-unit and route checks, and the
authenticated Homepage canary when enabled.

`--action test` records the exact repository hash and NixOS closure only after
all gates pass. `--action switch` refuses changed source and commits that exact
tested closure as the boot default. A failed or interrupted activation is rolled
back to the previous live generation. HUP, INT, and TERM trigger immediate
recovery; a target-side rollback timer remains the backstop for abrupt loss.

Debug mode adds the full repository validation gate before the rebuild and
prints extra systemd/journal context if failed units remain afterward.
EOF
}

target_host=""
build_host=""
build_locally=false
build_mode_override=""
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
    --build-mode)
      [[ $# -ge 2 && -n "${2:-}" ]] || { echo "blocked: --build-mode requires local, remote, balanced, or maximum-effort" >&2; exit 1; }
      build_mode_override="${2:-}"
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
if [[ "$build_locally" == "true" && -n "$build_mode_override" ]]; then
  echo "blocked: --build-locally cannot be combined with --build-mode" >&2
  exit 1
fi

need nix

local_attic_cache="http://127.0.0.1:8080/nixhomeserver"
if [[ "${DEPLOY_DRY_RUN:-}" != "1" ]] && nix_uses_substituter "$local_attic_cache"; then
  need curl nohup
  ensure_local_attic_tunnel \
    "$local_attic_cache/nix-cache-info" \
    "${NIXHOMESERVER_ATTIC_TUNNEL_SCRIPT:-$HOME/.local/bin/nixhomeserver-attic-tunnel}" \
    "${XDG_CACHE_HOME:-$HOME/.cache}/nixhomeserver-attic-tunnel.log"
fi

local_nix_gc_mode="$(nix_flake_var 'vars.localNixGCMode')"
case "$local_nix_gc_mode" in
  never|capacity|always) ;;
  *)
    echo "blocked: vars.localNixGCMode must be never, capacity, or always" >&2
    exit 1
    ;;
esac
local_nix_gc_retention_days="$(nix_flake_var 'toString vars.nixGcRetentionDays')"
local_disk_cleanup_trigger_percent="$(nix_flake_var 'toString vars.localDiskCleanup.triggerPercent')"
local_disk_cleanup_monitor_paths="$(nix_flake_var 'builtins.concatStringsSep " " vars.localDiskCleanup.monitorPaths')"
local_disk_cleanup_journal_vacuum_time="$(nix_flake_var 'vars.localDiskCleanup.journalVacuumTime')"

configured_build_mode="$(nix_flake_var 'vars.buildMode')"
if [[ -n "$build_mode_override" ]]; then
  build_mode="$build_mode_override"
elif [[ "$build_locally" == "true" ]]; then
  build_mode="local"
elif [[ -n "$build_host" ]]; then
  build_mode="remote"
else
  build_mode="$configured_build_mode"
fi

case "$build_mode" in
  local)
    build_locally=true
    if [[ -n "$build_host" ]]; then
      echo "blocked: --build-host can only be combined with --build-mode remote" >&2
      exit 1
    fi
    ;;
  remote)
    build_locally=false
    ;;
  balanced|maximum-effort)
    build_locally=true
    if [[ -n "$build_host" ]]; then
      echo "blocked: --build-host can only be combined with --build-mode remote" >&2
      exit 1
    fi
    ;;
  *)
    echo "blocked: build mode must be local, remote, balanced, or maximum-effort" >&2
    exit 1
    ;;
esac

local_build_slots="$(nix_flake_var 'toString vars.buildSlots.local')"
remote_build_slots="$(nix_flake_var 'toString vars.buildSlots.remote')"
local_build_cores="$(nix_flake_var 'toString vars.buildCores.local')"
remote_build_cores="$(nix_flake_var 'toString vars.buildCores.remote')"
host_platform="$(nix_flake_var 'vars.hostPlatform')"
builder_ssh_public_key="$(nix_flake_var 'vars.serverSSHPubKey')"

# A one-shot mode override must carry its own native Nix slot mapping rather
# than reusing the slots derived from the persistent vars.system.buildMode.
case "$build_mode" in
  local)
    local_build_slots="auto"
    remote_build_slots="0"
    local_build_cores="0"
    remote_build_cores="0"
    ;;
  remote)
    local_build_slots="0"
    remote_build_slots="auto"
    local_build_cores="0"
    remote_build_cores="0"
    ;;
  balanced)
    local_build_slots="2"
    remote_build_slots="2"
    local_build_cores="1"
    remote_build_cores="1"
    ;;
  maximum-effort)
    local_build_slots="auto"
    remote_build_slots="auto"
    local_build_cores="0"
    remote_build_cores="0"
    ;;
esac

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
  echo "mode=${build_mode}"
  echo "build_slots=local:${local_build_slots},remote:${remote_build_slots}"
  echo "build_cores=local:${local_build_cores},remote:${remote_build_cores}"
  echo "target_host=${target_host}"
  if [[ "$build_mode" == "balanced" || "$build_mode" == "maximum-effort" ]]; then
    echo "build_host=local+${target_host}"
  else
    echo "build_host=$([[ "$build_locally" == "true" ]] && echo local || echo "$build_host")"
  fi
  echo "hostname=${hostname}"
  echo "action=${action}"
  echo "debug=${debug}"
  case "$local_nix_gc_mode" in
    capacity)
      echo "local_gc=would run conservative workstation disk cleanup (nix gc + log/tmpfile) at ${local_disk_cleanup_trigger_percent}% on ${local_disk_cleanup_monitor_paths} before staging"
      ;;
    always)
      echo "local_gc=would run unconditional nix-store --gc on the workstation before staging"
      ;;
  esac
  if [[ "$action" == "test" ]]; then
    dry_run_rebuild_command=()
    build_nixos_rebuild_command dry_run_rebuild_command \
      build "$hostname" "$build_locally" "$target_host" "$build_host"
    echo -n "rebuild_command="
    print_quoted_command "${dry_run_rebuild_command[@]}"
    echo "activation_command=activate the returned closure through the guarded target-side test unit"
    echo "result=record source hash and exact passing closure"
  else
    echo "stamp_required=true"
    echo "activation_command=activate exact stamped closure in test mode"
    echo "boot_commit=only after failed-unit route and authenticated-canary gates pass"
  fi
  echo "rollback=restore previous live and boot generations on failure"
  exit 0
fi

case "$local_nix_gc_mode" in
  capacity)
    echo "checking workstation main SSD capacity"
    local_gc_runtime_dir="${XDG_RUNTIME_DIR:-/tmp}/nixhomeserver-${UID}"
    # Conservative cleanup: Nix store collection plus journal/tmpfile pruning,
    # gated on the main SSD reaching the configured percentage. Action-level
    # failures (for example journald/tmpfiles needing root) must never block a
    # deploy; the Nix collection still runs first.
    if ! DISK_CLEANUP_TRIGGER_PERCENT="$local_disk_cleanup_trigger_percent" \
        DISK_CLEANUP_MONITOR_PATHS="$local_disk_cleanup_monitor_paths" \
        DISK_CLEANUP_JOURNAL_VACUUM_TIME="$local_disk_cleanup_journal_vacuum_time" \
        DISK_CLEANUP_NIX_GC_RETENTION_DAYS="$local_nix_gc_retention_days" \
        DISK_CLEANUP_LOCK_PATH="$local_gc_runtime_dir/maintenance.lock" \
        DISK_CLEANUP_FAILURE_MARKER="$local_gc_runtime_dir/disk-cleanup-failed" \
        bash "$script_dir/helpers/disk-space-cleanup.sh"; then
      echo "warning: workstation disk cleanup did not fully succeed; continuing deploy" >&2
    fi
    ;;
  always)
    echo "collecting all unreferenced local Nix store paths"
    nix-store --gc
    ;;
esac

need git ssh tar

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
    BUILD_MODE="$build_mode" \
    LOCAL_BUILD_SLOTS="$local_build_slots" \
    REMOTE_BUILD_SLOTS="$remote_build_slots" \
    LOCAL_BUILD_CORES="$local_build_cores" \
    REMOTE_BUILD_CORES="$remote_build_cores" \
    HOST_PLATFORM="$host_platform" \
    BUILDER_SSH_PUBLIC_KEY="$builder_ssh_public_key" \
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
  "BUILD_MODE=$(printf '%q' "$build_mode")"
  "LOCAL_BUILD_SLOTS=$(printf '%q' "$local_build_slots")"
  "REMOTE_BUILD_SLOTS=$(printf '%q' "$remote_build_slots")"
  "LOCAL_BUILD_CORES=$(printf '%q' "$local_build_cores")"
  "REMOTE_BUILD_CORES=$(printf '%q' "$remote_build_cores")"
  "HOST_PLATFORM=$(printf '%q' "$host_platform")"
  "BUILDER_SSH_PUBLIC_KEY=$(printf '%q' "$builder_ssh_public_key")"
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
