#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
source "$script_dir/helpers/deploy-command.sh"
source "$script_dir/helpers/dashboard-build-mode.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/deploy.sh [--target <user@host>] [--build-mode local|remote|balanced|maximum-effort] [--build-host <user@host>] [--build-locally] [--console] [--action test|switch] [--hostname <flake-hostname>] [--debug]

Stage the current repo and run a NixOS rebuild.

Run this helper from a Git checkout. Copied directories and source ZIPs are
rejected because they do not provide a safe tracked-file deployment manifest.

By default, the target is vars.localAdminUser@vars.serverLanIP and the build
allocation comes from vars.system.buildMode, overridden by the build mode saved
in the Homepage dashboard when one is set. Local and remote use all available
slots on one machine, balanced uses two slots of four requested cores on each,
and maximum-effort uses all available slots on both. --build-mode overrides both
for one invocation. --build-locally remains an alias for --build-mode local.
Dry-runs report the configured vars.nix allocation and do not consult the
dashboard.

Fast mode performs high-value checks: host evaluation, build and target
free-space checks, a live test activation, failed-unit and route checks, and the
authenticated Homepage canary when enabled.

`--console` runs the guarded deploy as this machine's root identity instead of
reaching the target over SSH. It is the implemented route for a host whose
vars.identity.localAdminSudo policy is "password-authenticated": run it from the
server console as the local admin, and every non-interactive sudo the deploy
needs is already root. It must not be combined with --target or --build-host,
because it makes no remote connection.

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
consult_dashboard_build_mode=true
console=false
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
    --console)
      console=true
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
# Console mode is the local-root route: it opens no SSH connection to the
# target, so it cannot be combined with any option that names a remote host.
if [[ "$console" == "true" && -n "$target_host" ]]; then
  echo "blocked: --console cannot be combined with --target; it deploys to this host" >&2
  exit 1
fi
if [[ "$console" == "true" && -n "$build_host" ]]; then
  echo "blocked: --console cannot be combined with --build-host; it makes no remote connection" >&2
  exit 1
fi

need nix
need jq

local_attic_cache="http://127.0.0.1:8080/nixhomeserver"

deploy_config_json="$(NIXHOMESERVER_DEPLOY_NEED_HOSTNAME="$([[ -z "$hostname" ]] && echo 1 || echo 0)" \
  NIXHOMESERVER_DEPLOY_NEED_TARGET="$([[ -z "$target_host" ]] && echo 1 || echo 0)" \
  nix_flake_json '
  {
    localNixGCMode = vars.localNixGCMode;
    nixGcRetentionDays = vars.nixGcRetentionDays;
    localDiskCleanup = vars.localDiskCleanup;
    buildMode = vars.buildMode;
    buildSlots = vars.buildSlots;
    buildCores = vars.buildCores;
    hostPlatform = vars.hostPlatform;
    serverSSHPubKey = vars.serverSSHPubKey;
    # The sudo policy is a property of this configuration, not of the resolved
    # target, so it is always emitted: with --target set the guard must still
    # see a restricted policy and refuse before staging, instead of falling
    # back to "unknown" and failing midway on non-interactive sudo.
    localAdminSudo = vars.localAdminSudo;
    localAdminSudoDeployRequiresPasswordlessSudo = vars.localAdminSudoPolicy.deployRequiresPasswordlessSudo;
    localAdminSudoDeployBlockedReason = vars.localAdminSudoPolicy.deployBlockedReason;
  }
  // lib.optionalAttrs (builtins.getEnv "NIXHOMESERVER_DEPLOY_NEED_HOSTNAME" == "1") {
    hostname = vars.hostname;
  }
  // lib.optionalAttrs (builtins.getEnv "NIXHOMESERVER_DEPLOY_NEED_TARGET" == "1") {
    localAdminUser = if vars ? localAdminUser then vars.localAdminUser else vars.identity.localAdminUser;
    serverLanIP = vars.serverLanIP;
  }
')"
local_nix_gc_mode="$(jq -er '.localNixGCMode' <<<"$deploy_config_json")"
case "$local_nix_gc_mode" in
  never|capacity|always) ;;
  *)
    echo "blocked: vars.localNixGCMode must be never, capacity, or always" >&2
    exit 1
    ;;
esac
local_nix_gc_retention_days="$(jq -er '.nixGcRetentionDays' <<<"$deploy_config_json")"
local_disk_cleanup_trigger_percent="$(jq -er '.localDiskCleanup.triggerPercent' <<<"$deploy_config_json")"
local_disk_cleanup_monitor_paths="$(jq -er '.localDiskCleanup.monitorPaths | join(" ")' <<<"$deploy_config_json")"
local_disk_cleanup_journal_vacuum_time="$(jq -er '.localDiskCleanup.journalVacuumTime' <<<"$deploy_config_json")"

configured_build_mode="$(jq -er '.buildMode' <<<"$deploy_config_json")"

# Resolve the deployment hostname and target before build-mode selection: the
# dashboard-selected build mode is stored on the target server and is read as
# the default allocation for real deploys.
if [[ -z "$hostname" ]]; then
  hostname="$(jq -er '.hostname' <<<"$deploy_config_json")"
fi
if [[ ! "$hostname" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; then
  echo "blocked: --hostname must be one DNS hostname label" >&2
  exit 1
fi

if [[ "$console" == "true" ]]; then
  # Console mode deploys to this machine and keeps no SSH hop to the target, so
  # the executor's local path runs every privileged step as this root identity.
  # The name is only used for messages and for refusing an accidental --target
  # above.
  target_host="console"
elif [[ -z "$target_host" ]]; then
  local_admin_user="$(jq -er '.localAdminUser' <<<"$deploy_config_json")"
  target_address="$(jq -er '.serverLanIP' <<<"$deploy_config_json")"
  target_host="${local_admin_user}@${target_address}"
fi
console_mode="$console"

# Refuse early when this deploy cannot authenticate the target's non-interactive
# sudo contract, instead of failing midway through a staged deploy. A
# restricted policy has exactly one route: the --console deploy run as root at
# the server console, which is also the only supported way to transition onto
# that policy, because the activation that removes the grant also removes the
# authorization its own post-activation steps need. A passwordless deploy sudo
# grant remains the operator's explicit choice in vars.identity.localAdminSudo;
# this only reports the consequence of choosing otherwise.
source "$script_dir/helpers/local-admin-sudo-guard.sh"
enforce_local_admin_sudo_policy

if [[ "$console" == "true" ]]; then
  # Console mode is the local-root route for a host whose sudo policy is
  # "password-authenticated". It also builds here: the restricted policy drops
  # the local admin from nix.settings.trusted-users, so a distributed or remote
  # build driven over SSH as that account could not write the Nix store. Local
  # mode uses every slot this machine has, which is the full server allocation.
  if [[ -n "$build_mode_override" && "$build_mode_override" != "local" ]]; then
    echo "blocked: --console only builds with --build-mode local; remote and distributed builds run over SSH as the local admin, which the restricted policy leaves unable to write the Nix store" >&2
    exit 1
  fi
  build_mode="local"
  build_locally=true
  build_host=""
  # No SSH hop exists, so the dashboard-selected allocation on the target is
  # not this deploy's to read.
  consult_dashboard_build_mode=false
fi

if [[ -n "$build_mode_override" ]]; then
  build_mode="$build_mode_override"
elif [[ "$build_locally" == "true" ]]; then
  build_mode="local"
elif [[ -n "$build_host" ]]; then
  build_mode="remote"
else
  build_mode="$configured_build_mode"
  if [[ "${DEPLOY_DRY_RUN:-}" != "1" && "$consult_dashboard_build_mode" == "true" ]]; then
    if dashboard_build_mode="$(read_dashboard_build_mode "$target_host")"; then
      echo "build mode: using dashboard-selected '${dashboard_build_mode}' (vars.nix default '${configured_build_mode}')"
      build_mode="$dashboard_build_mode"
    fi
  fi
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

local_build_slots="$(jq -er '.buildSlots.local' <<<"$deploy_config_json")"
remote_build_slots="$(jq -er '.buildSlots.remote' <<<"$deploy_config_json")"
local_build_cores="$(jq -er '.buildCores.local' <<<"$deploy_config_json")"
remote_build_cores="$(jq -er '.buildCores.remote' <<<"$deploy_config_json")"
host_platform="$(jq -er '.hostPlatform' <<<"$deploy_config_json")"
builder_ssh_public_key="$(jq -er '.serverSSHPubKey' <<<"$deploy_config_json")"

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
    local_build_cores="4"
    remote_build_cores="4"
    ;;
  maximum-effort)
    local_build_slots="auto"
    remote_build_slots="auto"
    local_build_cores="0"
    remote_build_cores="0"
    ;;
esac

if [[ "$build_locally" != "true" && -z "$build_host" ]]; then
  build_host="$target_host"
fi

# The workstation Attic cache is only worth recovering once the resolved
# allocation is known: only a workstation build consumes it through the local
# substituter, and a purely remote or server-side build must not be blocked by
# a cache that cannot help it. Recovery is best effort because Nix keeps its
# public caches either way.
recover_local_attic_tunnel_if_needed \
  "$build_locally" \
  "$local_attic_cache" \
  "${NIXHOMESERVER_ATTIC_TUNNEL_SCRIPT:-$HOME/.local/bin/nixhomeserver-attic-tunnel}" \
  "${XDG_CACHE_HOME:-$HOME/.cache}/nixhomeserver-attic-tunnel.log"

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
  echo "console=${console_mode}"
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
      build "$hostname" "$build_locally" "$target_host" "$build_host" "$console_mode"
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
    CONSOLE_MODE="$console_mode" \
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

# Remove the staged archive through the namespace contract rather than a bare
# `rm`, so a crafted path cannot redirect the cleanup. If the helper cannot be
# found the archive is left for the 48h namespace expiry to reclaim; deleting an
# unvalidated path would be the worse failure.
cleanup_archive() {
  if [[ -f "$tmpdir/scripts/helpers/deploy-archive-cleanup.sh" ]]; then
    bash "$tmpdir/scripts/helpers/deploy-archive-cleanup.sh" remove "$REMOTE_ARCHIVE" || true
  fi
}

cleanup_remote() {
  local status=$?
  # The constrained helper lives in the extracted tree: use it before removing
  # that tree, even when extraction failed before the cd. Preserve executor or
  # tar failure status regardless of best-effort cleanup results.
  cleanup_archive
  rm -rf "$tmpdir" || true
  exit "$status"
}

tmpdir="$(mktemp -d)"
trap cleanup_remote EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
cd "$tmpdir"

bash ./scripts/helpers/deploy-executor.sh
EOF

echo "Deploy ${action} completed."
