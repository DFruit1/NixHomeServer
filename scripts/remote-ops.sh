#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage:
  scripts/remote-ops.sh deploy --target <user@host> [--build-host <user@host>] [--action test|switch] [--hostname <flake-hostname>] [--archive-sha <sha256>] [--full-check]
  scripts/remote-ops.sh validate [--full] [--run-flake-check] [--skip-flake-check] [--archive-sha <sha256>]
  scripts/remote-ops.sh generate-secrets
EOF
}

validation_cache_dir="${DEPLOY_VALIDATION_CACHE_DIR:-$HOME/.cache/nixhomeserver/deploy-validation}"
validation_stamp_max_age_seconds="${DEPLOY_VALIDATION_STAMP_MAX_AGE_SECONDS:-86400}"
min_build_host_free_bytes=$((10 * 1024 * 1024 * 1024))
min_remote_tmp_free_bytes=$((1 * 1024 * 1024 * 1024))

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
  local target_host="$1"
  local build_host="$2"
  local expected_lan_ip="$3"
  local target_matches build_matches

  target_matches=0
  build_matches=0
  if host_matches_expected_lan_ip "$target_host" "$expected_lan_ip"; then
    target_matches=1
  fi
  if host_matches_expected_lan_ip "$build_host" "$expected_lan_ip"; then
    build_matches=1
  fi

  if (( target_matches == 1 && build_matches == 1 )); then
    return
  fi

  echo "ℹ️ Transition deploy: the current SSH/build endpoint differs from vars.serverLanIP."
  echo "   Target host: ${target_host}"
  echo "   Build host: ${build_host}"
  echo "   Expected reserved LAN IP from vars.nix: ${expected_lan_ip}"
  echo "   This is advisory only. Deploy will continue, but post-cutover validation must still confirm SSH and runtime readiness on ${expected_lan_ip}."
}

human_bytes() {
  local bytes="$1"
  awk -v bytes="$bytes" 'BEGIN { printf "%.2f GiB", bytes / 1073741824 }'
}

check_build_host_storage() {
  local build_host="$1"
  local sandbox_build_dir build_backing_path build_available_bytes tmp_available_bytes

  echo "ℹ️ Checking build host free space on ${build_host}…"

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

  echo "ℹ️ Build host storage summary: sandbox-build-dir=${sandbox_build_dir}, backing-path=${build_backing_path}, available=$(human_bytes "$build_available_bytes"), /tmp=$(human_bytes "$tmp_available_bytes")"

  if (( build_available_bytes < min_build_host_free_bytes )); then
    echo "❌ Insufficient free space on build host"
    echo "   sandbox-build-dir: ${sandbox_build_dir}"
    echo "   backing path: ${build_backing_path}"
    echo "   available: ${build_available_bytes} bytes ($(human_bytes "$build_available_bytes"))"
    echo "   required: ${min_build_host_free_bytes} bytes ($(human_bytes "$min_build_host_free_bytes"))"
    exit 1
  fi

  if (( tmp_available_bytes < min_remote_tmp_free_bytes )); then
    echo "❌ Insufficient free space on build host"
    echo "   sandbox-build-dir: /tmp"
    echo "   backing path: /tmp"
    echo "   available: ${tmp_available_bytes} bytes ($(human_bytes "$tmp_available_bytes"))"
    echo "   required: ${min_remote_tmp_free_bytes} bytes ($(human_bytes "$min_remote_tmp_free_bytes"))"
    exit 1
  fi
}

validation_stamp_file() {
  local archive_sha="$1"
  printf '%s/%s.json\n' "$validation_cache_dir" "$archive_sha"
}

has_fresh_validation_stamp() {
  local archive_sha="$1"
  local require_flake="${2:-false}"
  local stamp_file now created_epoch stamp_archive_sha flake_ok repo_ok

  stamp_file="$(validation_stamp_file "$archive_sha")"
  if [[ ! -f "$stamp_file" ]]; then
    return 1
  fi

  stamp_archive_sha="$(jq -r '.archiveSha256 // ""' "$stamp_file")"
  flake_ok="$(jq -r '.flakeCheckSucceeded // false' "$stamp_file")"
  repo_ok="$(jq -r '.checkRepoSucceeded // false' "$stamp_file")"
  created_epoch="$(jq -r '.createdEpoch // 0' "$stamp_file")"
  now="$(date +%s)"

  if [[ "$stamp_archive_sha" != "$archive_sha" || "$repo_ok" != "true" ]]; then
    return 1
  fi
  if [[ "$require_flake" == "true" && "$flake_ok" != "true" ]]; then
    return 1
  fi
  if ! [[ "$created_epoch" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  if (( now - created_epoch > validation_stamp_max_age_seconds )); then
    return 1
  fi

  return 0
}

write_validation_stamp() {
  local archive_sha="$1"
  local flake_ok="$2"
  local created_epoch stamp_file

  created_epoch="$(date +%s)"
  stamp_file="$(validation_stamp_file "$archive_sha")"
  mkdir -p "$validation_cache_dir"
  jq -n \
    --arg archiveSha256 "$archive_sha" \
    --argjson createdEpoch "$created_epoch" \
    --argjson flakeCheckSucceeded "$flake_ok" \
    '{
      archiveSha256: $archiveSha256,
      createdEpoch: $createdEpoch,
      flakeCheckSucceeded: $flakeCheckSucceeded,
      checkRepoSucceeded: true
    }' >"$stamp_file"
}

run_validate_repo() {
  local full_mode="$1"
  local run_flake_check="$2"
  local skip_flake_check="$3"
  local archive_sha="$4"
  local flake_check_completed=false
  local validate_args=()

  if [[ "$full_mode" == true ]]; then
    validate_args+=(--full)
  fi
  if [[ "$run_flake_check" == true ]]; then
    validate_args+=(--run-flake-check)
  fi
  if [[ "$skip_flake_check" == true ]]; then
    validate_args+=(--skip-flake-check)
  fi

  ./scripts/validate-repo.sh "${validate_args[@]}"

  if [[ "$skip_flake_check" == false ]]; then
    if [[ "$full_mode" == true || "$run_flake_check" == true ]]; then
      flake_check_completed=true
    fi
  fi

  write_validation_stamp "$archive_sha" "$flake_check_completed"
}

run_remote_runtime_readiness() {
  local target_host="$1"
  local full_check="${2:-false}"
  local repo_archive remote_archive

  repo_archive="$(mktemp /tmp/check-runtime-readiness.XXXXXX.tar)"
  trap 'rm -f "$repo_archive"' RETURN
  create_deploy_repo_archive "$repo_archive"
  remote_archive="$(stage_archive_on_remote "$repo_archive" "$target_host" "check-runtime-readiness")"

  ssh -T "$target_host" "REMOTE_ARCHIVE=$(printf '%q' "$remote_archive") FULL_CHECK=$(printf '%q' "$full_check") bash -s" <<'EOF'
set -euo pipefail
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir" "$REMOTE_ARCHIVE"' EXIT
tar -C "$tmpdir" -xf "$REMOTE_ARCHIVE"
chmod +x "$tmpdir/scripts/check-runtime-readiness.sh"
cd "$tmpdir"
readiness_args=(--profile deploy)
if [[ "${FULL_CHECK:-false}" == "true" ]]; then
  readiness_args+=(--deep)
fi
sudo env RUNTIME_READINESS_REPO_ROOT="$PWD" ./scripts/check-runtime-readiness.sh "${readiness_args[@]}"
EOF
}

run_rebuild() {
  local rebuild_action="$1"
  local hostname="$2"
  local target_host="$3"
  local build_host="$4"

  if [[ "$target_host" == "$build_host" ]]; then
    nix run nixpkgs#nixos-rebuild -- "$rebuild_action" \
      --flake ".#${hostname}" \
      --sudo
    return 0
  fi

  nix run nixpkgs#nixos-rebuild -- "$rebuild_action" \
    --flake ".#${hostname}" \
    --target-host "$target_host" \
    --sudo
}

deploy_main() {
  local target_host=""
  local build_host=""
  local action="test"
  local hostname=""
  local archive_sha=""
  local full_check=false
  local resolved_hostname expected_lan_ip

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
      --archive-sha)
        archive_sha="${2:-}"
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
    echo "❌ deploy requires --target." >&2
    exit 1
  fi
  if [[ -z "$build_host" ]]; then
    build_host="$target_host"
  fi
  if [[ "$action" != "test" && "$action" != "switch" ]]; then
    echo "❌ --action must be 'test' or 'switch'." >&2
    exit 1
  fi

  resolved_hostname="${hostname:-$(nix_flake_var 'vars.hostname')}"
  expected_lan_ip="$(nix_flake_var 'vars.serverLanIP')"
  if [[ -z "$archive_sha" ]]; then
    archive_sha="$(hash_deploy_repo_archive)"
  fi

  print_transition_notice_if_needed "$target_host" "$build_host" "$expected_lan_ip"
  check_build_host_storage "$build_host"

  if has_fresh_validation_stamp "$archive_sha"; then
    echo "ℹ️ Reusing remote validation stamp for archive ${archive_sha}; skipping remote repository checks."
  else
    echo "ℹ️ Running repository checks on ${build_host}…"
    run_validate_repo true false true "$archive_sha"
  fi

  echo "ℹ️ Running remote nixos-rebuild test…"
  run_rebuild test "$resolved_hostname" "$target_host" "$build_host"

  if [[ "$target_host" == "$build_host" ]]; then
    echo "ℹ️ Checking for failed units on ${target_host}…"
    sudo systemctl --failed --no-pager

    echo "ℹ️ Running runtime readiness checks on ${target_host}…"
    readiness_args=(--profile deploy)
    if [[ "$full_check" == true ]]; then
      readiness_args+=(--deep)
    fi
    sudo env RUNTIME_READINESS_REPO_ROOT="$PWD" ./scripts/check-runtime-readiness.sh "${readiness_args[@]}"
  else
    echo "ℹ️ Checking for failed units on ${target_host}…"
    ssh "$target_host" "sudo systemctl --failed --no-pager"

    echo "ℹ️ Running runtime readiness checks on ${target_host}…"
    run_remote_runtime_readiness "$target_host" "$full_check"
  fi

  if [[ "$action" == "switch" ]]; then
    echo "ℹ️ Running remote nixos-rebuild switch…"
    run_rebuild switch "$resolved_hostname" "$target_host" "$build_host"
  fi
}

validate_main() {
  local archive_sha=""
  local full_mode=false
  local run_flake_check=false
  local skip_flake_check=false
  local mode_specified=false

  while (($# > 0)); do
    case "$1" in
      --full)
        full_mode=true
        mode_specified=true
        shift
        ;;
      --run-flake-check)
        run_flake_check=true
        mode_specified=true
        shift
        ;;
      --skip-flake-check)
        skip_flake_check=true
        mode_specified=true
        shift
        ;;
      --archive-sha)
        archive_sha="${2:-}"
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

  if [[ "$mode_specified" == false ]]; then
    full_mode=true
  fi

  if [[ -z "$archive_sha" ]]; then
    archive_sha="$(hash_deploy_repo_archive)"
  fi

  run_validate_repo "$full_mode" "$run_flake_check" "$skip_flake_check" "$archive_sha"
}

generate_secrets_main() {
  ./scripts/generate-all-secrets.sh
}

subcommand="${1:-}"
if [[ -z "$subcommand" ]]; then
  usage >&2
  exit 1
fi
shift

case "$subcommand" in
  deploy)
    deploy_main "$@"
    ;;
  validate)
    validate_main "$@"
    ;;
  generate-secrets)
    generate_secrets_main "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
