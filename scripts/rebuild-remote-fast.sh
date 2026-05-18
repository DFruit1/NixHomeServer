#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/rebuild-remote-fast.sh [--target <user@host>] [--build-host <user@host>] [--action test|switch] [--hostname <flake-hostname>]

Fast remote rebuild entrypoint for custom app iteration.

This stages the current repo archive to the remote build host and runs
nixos-rebuild there. It intentionally skips repository validation, flake
checks, failed-unit checks, runtime readiness, storage checks, and the guarded
test-before-switch flow.

With no arguments, the SSH target defaults to vars.localAdminUser@vars.hostname
and the flake hostname defaults to vars.hostname.

Examples:
  ./scripts/rebuild-remote-fast.sh
  ./scripts/rebuild-remote-fast.sh --action test
  ./scripts/rebuild-remote-fast.sh --target "<admin>@<hostname>"
  ./scripts/rebuild-remote-fast.sh --target "<admin>@<hostname>" --build-host "<admin>@<hostname>" --hostname server
EOF
}

target_host=""
build_host=""
action="switch"
hostname=""
repo_archive=""

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
    --action)
      action="${2:-}"
      shift 2
      ;;
    --hostname)
      hostname="${2:-}"
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

if [[ "$action" != "test" && "$action" != "switch" ]]; then
  echo "❌ --action must be 'test' or 'switch'." >&2
  exit 1
fi

if [[ -z "$hostname" || -z "$target_host" ]]; then
  need nix
fi

if [[ -z "$hostname" ]]; then
  hostname="$(nix_flake_var 'vars.hostname')"
fi

if [[ -z "$target_host" ]]; then
  local_admin_user="$(nix_flake_var 'if vars ? localAdminUser then vars.localAdminUser else vars.kanidmAdminUser')"
  target_host="${local_admin_user}@${hostname}"
fi

if [[ -z "$build_host" ]]; then
  build_host="$target_host"
fi

cleanup_local_archive() {
  if [[ -n "$repo_archive" && -f "$repo_archive" ]]; then
    rm -f "$repo_archive"
  fi
}

trap cleanup_local_archive EXIT

need ssh scp tar

echo "ℹ️ Staging repo archive on ${build_host}…"
repo_archive="$(mktemp /tmp/rebuild-remote-fast-repo.XXXXXX.tar)"
create_deploy_repo_archive "$repo_archive"
remote_archive="$(stage_archive_on_remote "$repo_archive" "$build_host" "rebuild-remote-fast-repo")"

remote_env=(
  "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive")"
  "TARGET_HOST=$(printf '%q' "$target_host")"
  "BUILD_HOST=$(printf '%q' "$build_host")"
  "ACTION=$(printf '%q' "$action")"
  "HOSTNAME_ARG=$(printf '%q' "$hostname")"
)
remote_command="$(printf '%s ' "${remote_env[@]}")bash -s"

echo "ℹ️ Running remote nixos-rebuild ${action} on ${build_host}…"
ssh -T "$build_host" "$remote_command" <<'EOF'
set -euo pipefail
export NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes
accept-flake-config = true}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
cd "$tmpdir"

cmd=(nix run nixpkgs#nixos-rebuild -- "$ACTION" --flake ".#${HOSTNAME_ARG}" --sudo)
if [[ "$TARGET_HOST" != "$BUILD_HOST" ]]; then
  cmd+=(--target-host "$TARGET_HOST")
fi

"${cmd[@]}"
EOF

echo "✅ Fast remote rebuild completed."
