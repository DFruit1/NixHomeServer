#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/deploy-with-validation.sh --target <user@host> [--build-host <user@host>] [--action test|switch] [--hostname <flake-hostname>] [--full-check]

Guarded deploy entrypoint for this repo.

This stages the repo archive to the remote build host and runs all Nix
evaluation, validation, build, and activation there.

Examples:
  ./scripts/deploy-with-validation.sh --target "<admin>@<hostname>" --build-host "<admin>@<hostname>" --action test
  ./scripts/deploy-with-validation.sh --target "<admin>@<hostname>" --build-host "<admin>@<hostname>" --action switch
  ./scripts/deploy-with-validation.sh --target "<admin>@<hostname>" --build-host "<admin>@<hostname>" --action test --full-check
EOF
}

target_host=""
build_host=""
action="test"
hostname=""
full_check=false
repo_archive=""
repo_archive_sha=""

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
    --full-check)
      full_check=true
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

if [[ -z "$target_host" ]]; then
  usage >&2
  exit 1
fi

if [[ -z "$build_host" ]]; then
  build_host="$target_host"
fi

if [[ "$action" != "test" && "$action" != "switch" ]]; then
  echo "❌ --action must be 'test' or 'switch'." >&2
  exit 1
fi

cleanup_local_archive() {
  if [[ -n "$repo_archive" && -f "$repo_archive" ]]; then
    rm -f "$repo_archive"
  fi
}

trap cleanup_local_archive EXIT

run_remote_deploy() {
  local remote_archive remote_command
  local remote_env=(
    "TARGET_HOST=$(printf '%q' "$target_host")"
    "BUILD_HOST=$(printf '%q' "$build_host")"
    "ACTION=$(printf '%q' "$action")"
    "ARCHIVE_SHA=$(printf '%q' "$repo_archive_sha")"
    "FULL_CHECK=$(printf '%q' "$full_check")"
  )

  if [[ -n "$hostname" ]]; then
    remote_env+=("HOSTNAME_ARG=$(printf '%q' "$hostname")")
  fi
  if [[ -n "${DEPLOY_VALIDATION_CACHE_DIR:-}" ]]; then
    remote_env+=("DEPLOY_VALIDATION_CACHE_DIR=$(printf '%q' "$DEPLOY_VALIDATION_CACHE_DIR")")
  fi
  if [[ -n "${DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS:-}" ]]; then
    remote_env+=("DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS=$(printf '%q' "$DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS")")
  fi

  remote_archive="$(stage_archive_on_remote "$repo_archive" "$build_host" "deploy-with-validation-repo")"
  remote_env=("REMOTE_ARCHIVE=$(printf '%q' "$remote_archive")" "${remote_env[@]}")
  remote_command="$(printf '%s ' "${remote_env[@]}")bash -s"

  ssh -T "$build_host" "$remote_command" <<'EOF'
set -euo pipefail
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
chmod +x "$tmpdir/scripts/remote-ops.sh"
cd "$tmpdir"
cmd=(./scripts/remote-ops.sh deploy --target "$TARGET_HOST" --build-host "$BUILD_HOST" --action "$ACTION" --archive-sha "$ARCHIVE_SHA")
if [[ -n "${HOSTNAME_ARG:-}" ]]; then
  cmd+=(--hostname "$HOSTNAME_ARG")
fi
if [[ "${FULL_CHECK:-false}" == "true" ]]; then
  cmd+=(--full-check)
fi
"${cmd[@]}"
EOF
}

need jq ssh scp tar

repo_archive="$(mktemp /tmp/deploy-with-validation-repo.XXXXXX.tar)"
create_deploy_repo_archive "$repo_archive"
repo_archive_sha="$(sha256_file "$repo_archive")"

run_remote_deploy

echo "✅ Deploy validation completed."
