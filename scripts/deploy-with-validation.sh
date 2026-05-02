#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/deploy-with-validation.sh --target <user@host> [--build-host <user@host> | --local-build] [--action test|switch] [--hostname <flake-hostname>]

Guarded deploy entrypoint for this repo.

Default mode stages the repo archive to the remote build host and runs all Nix
evaluation, validation, build, and activation there. `--local-build` is an
explicit compatibility path for operators who still want workstation-side
evaluation and builds.

Examples:
  ./scripts/deploy-with-validation.sh --target "dsaw@server" --build-host "dsaw@server" --action test
  ./scripts/deploy-with-validation.sh --target "dsaw@server" --build-host "dsaw@server" --action switch
  ./scripts/deploy-with-validation.sh --target "dsaw@server" --local-build --action test --hostname server
EOF
}

target_host=""
build_host=""
local_build=false
action="test"
hostname=""
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
    --local-build)
      local_build=true
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

if [[ "$local_build" == true && -n "$build_host" ]]; then
  echo "❌ --local-build cannot be combined with --build-host." >&2
  exit 1
fi

if [[ "$local_build" == false && -z "$build_host" ]]; then
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

host_part() {
  local host_spec="$1"
  if [[ "$host_spec" == *@* ]]; then
    printf '%s\n' "${host_spec##*@}"
  else
    printf '%s\n' "$host_spec"
  fi
}

host_matches_expected_lan_ip() {
  local host_spec="$1"
  local expected_lan_ip="$2"
  local host_value resolved

  host_value="$(host_part "$host_spec")"
  if [[ "$host_value" == "$expected_lan_ip" ]]; then
    return 0
  fi

  if [[ "$host_value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    return 1
  fi

  if ! command -v getent >/dev/null 2>&1; then
    return 1
  fi

  while read -r resolved _; do
    if [[ "$resolved" == "$expected_lan_ip" ]]; then
      return 0
    fi
  done < <(getent ahostsv4 "$host_value" 2>/dev/null || true)

  return 1
}

print_transition_notice_if_needed() {
  local expected_lan_ip="$1"
  local target_matches build_matches build_host_display

  target_matches=0
  build_matches=0
  if host_matches_expected_lan_ip "$target_host" "$expected_lan_ip"; then
    target_matches=1
  fi
  if [[ "$local_build" == true ]]; then
    build_matches=1
    build_host_display="local workstation"
  else
    if host_matches_expected_lan_ip "$build_host" "$expected_lan_ip"; then
      build_matches=1
    fi
    build_host_display="$build_host"
  fi

  if (( target_matches == 1 && build_matches == 1 )); then
    return
  fi

  echo "ℹ️ Transition deploy: the current SSH/build endpoint differs from vars.serverLanIP."
  echo "   Target host: ${target_host}"
  echo "   Build host: ${build_host_display}"
  echo "   Expected reserved LAN IP from vars.nix: ${expected_lan_ip}"
  echo "   This is advisory only. Deploy will continue, but post-cutover validation must still confirm SSH and runtime readiness on ${expected_lan_ip}."
}

resolve_local_hostname() {
  if [[ -n "$hostname" ]]; then
    printf '%s\n' "$hostname"
    return 0
  fi

  nix_flake_var 'vars.hostname'
}

ensure_local_build_system_matches() {
  local resolved_hostname="$1"
  local local_system target_system

  local_system="$(nix eval --impure --raw --expr 'builtins.currentSystem')"
  target_system="$(nix eval --raw ".#nixosConfigurations.${resolved_hostname}.pkgs.stdenv.hostPlatform.system")"

  if [[ "$local_system" == "$target_system" ]]; then
    return 0
  fi

  echo "❌ --local-build requires the current workstation system to match the target host configuration."
  echo "   Local currentSystem: ${local_system}"
  echo "   Target system: ${target_system}"
  exit 1
}

run_local_runtime_readiness() {
  local archive_path="$1"
  local remote_archive

  remote_archive="$(stage_archive_on_remote "$archive_path" "$target_host" "check-runtime-readiness")"

  ssh -tt "$target_host" "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive") bash -s" <<'EOF'
set -euo pipefail
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
chmod +x "$tmpdir/scripts/check-runtime-readiness.sh"
cd "$tmpdir"
sudo env RUNTIME_READINESS_REPO_ROOT="$PWD" ./scripts/check-runtime-readiness.sh --profile deploy
EOF
}

run_remote_deploy() {
  local remote_archive remote_command
  local remote_env=(
    "TARGET_HOST=$(printf '%q' "$target_host")"
    "BUILD_HOST=$(printf '%q' "$build_host")"
    "ACTION=$(printf '%q' "$action")"
    "ARCHIVE_SHA=$(printf '%q' "$repo_archive_sha")"
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

  ssh -tt "$build_host" "$remote_command" <<'EOF'
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
"${cmd[@]}"
EOF
}

if [[ "$local_build" == true ]]; then
  need nix jq ssh scp tar

  resolved_hostname="$(resolve_local_hostname)"
  expected_lan_ip="$(nix_flake_var 'vars.serverLanIP')"

  print_transition_notice_if_needed "$expected_lan_ip"
  ensure_local_build_system_matches "$resolved_hostname"

  echo "ℹ️ Running local repository checks…"
  ./scripts/validate-repo.sh --full --skip-flake-check

  echo "ℹ️ Running local nixos-rebuild test…"
  nix run nixpkgs#nixos-rebuild -- test \
    --flake ".#${resolved_hostname}" \
    --target-host "$target_host" \
    --sudo \
    --ask-sudo-password

  echo "ℹ️ Checking for failed units on ${target_host}…"
  ssh -t "$target_host" "sudo systemctl --failed --no-pager"

  echo "ℹ️ Running runtime readiness checks on ${target_host}…"
  repo_archive="$(mktemp /tmp/deploy-with-validation-repo.XXXXXX.tar)"
  create_deploy_repo_archive "$repo_archive"
  run_local_runtime_readiness "$repo_archive"

  if [[ "$action" == "switch" ]]; then
    echo "ℹ️ Running local nixos-rebuild switch…"
    nix run nixpkgs#nixos-rebuild -- switch \
      --flake ".#${resolved_hostname}" \
      --target-host "$target_host" \
      --sudo \
      --ask-sudo-password
  fi

  echo "✅ Deploy validation completed."
  exit 0
fi

need jq ssh scp tar

repo_archive="$(mktemp /tmp/deploy-with-validation-repo.XXXXXX.tar)"
create_deploy_repo_archive "$repo_archive"
repo_archive_sha="$(sha256_file "$repo_archive")"

run_remote_deploy

echo "✅ Deploy validation completed."
