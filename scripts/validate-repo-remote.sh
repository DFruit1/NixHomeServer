#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/validate-repo-remote.sh --host <user@host> [--full] [--run-flake-check] [--skip-flake-check]

Stage the current repo archive on a remote host and run the repository
validation gate there. When no validation mode is specified, the remote wrapper
defaults to `--full`.
EOF
}

remote_host=""
repo_archive=""
repo_archive_sha=""
validate_args=()

while (($# > 0)); do
  case "$1" in
    --host)
      remote_host="${2:-}"
      shift 2
      ;;
    --full|--run-flake-check|--skip-flake-check)
      validate_args+=("$1")
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

if [[ -z "$remote_host" ]]; then
  usage >&2
  exit 1
fi

cleanup_local_archive() {
  if [[ -n "$repo_archive" && -f "$repo_archive" ]]; then
    rm -f "$repo_archive"
  fi
}

trap cleanup_local_archive EXIT

need jq ssh scp tar

repo_archive="$(mktemp /tmp/validate-repo-remote.XXXXXX.tar)"
create_deploy_repo_archive "$repo_archive"
repo_archive_sha="$(sha256_file "$repo_archive")"
remote_archive="$(stage_archive_on_remote "$repo_archive" "$remote_host" "validate-repo-remote")"

remote_env=(
  "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive")"
  "ARCHIVE_SHA=$(printf '%q' "$repo_archive_sha")"
)
if [[ -n "${DEPLOY_VALIDATION_CACHE_DIR:-}" ]]; then
  remote_env+=("DEPLOY_VALIDATION_CACHE_DIR=$(printf '%q' "$DEPLOY_VALIDATION_CACHE_DIR")")
fi
if [[ -n "${DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS:-}" ]]; then
  remote_env+=("DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS=$(printf '%q' "$DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS")")
fi

remote_command="$(printf '%s ' "${remote_env[@]}")bash -s"
if ((${#validate_args[@]} > 0)); then
  remote_command+=" --"
  for validate_arg in "${validate_args[@]}"; do
    remote_command+=" $(printf '%q' "$validate_arg")"
  done
fi

ssh -tt "$remote_host" "$remote_command" <<'EOF'
set -euo pipefail
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
chmod +x "$tmpdir/scripts/remote-ops.sh"
cd "$tmpdir"
cmd=(./scripts/remote-ops.sh validate --archive-sha "$ARCHIVE_SHA")
while (($# > 0)); do
  cmd+=("$1")
  shift
done
"${cmd[@]}"
EOF
