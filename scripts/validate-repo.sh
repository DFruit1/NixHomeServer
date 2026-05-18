#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/validate-repo.sh [--full] [--run-flake-check] [--skip-flake-check]

Run the local repository validation gate.

Default mode:
  - runs the lean script suite through scripts/tests/run-script-tests.sh
  - does not run the flake check by default
  - does not build lint or Rust check derivations

  Use --run-flake-check to include `nix flake check --no-build`.

Full mode:
  - runs `nix flake check --no-build` unless --skip-flake-check is used
  - runs the broad script suite through scripts/tests/run-script-tests.sh --full
  - builds selected lint and Rust check derivations

Examples:
  scripts/validate-repo.sh
  scripts/validate-repo.sh --run-flake-check
  scripts/validate-repo.sh --full
  scripts/validate-repo.sh --full --skip-flake-check
EOF
}

full_mode=false
run_flake_check=false
skip_flake_check=false
tests_dir="${VALIDATE_REPO_TESTS_DIR:-$repo_root/scripts/tests}"
eval_cache_dir=""
validation_cache_dir="${DEPLOY_VALIDATION_CACHE_DIR:-$repo_root/.cache/deploy-validation}"
flake_check_completed=false

cleanup_tmpdirs() {
  if [[ -n "$eval_cache_dir" && -d "$eval_cache_dir" ]]; then
    rm -rf "$eval_cache_dir"
  fi
}

trap cleanup_tmpdirs EXIT

while (($# > 0)); do
  case "$1" in
    --full)
      full_mode=true
      shift
      ;;
    --run-flake-check)
      run_flake_check=true
      shift
      ;;
    --skip-flake-check)
      skip_flake_check=true
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

need nix jq

if [[ -z "${REPO_NIX_EVAL_CACHE_DIR:-}" ]]; then
  eval_cache_dir="$(mktemp -d)"
  export REPO_NIX_EVAL_CACHE_DIR="$eval_cache_dir"
fi

current_system() {
  nix eval --impure --raw --expr 'builtins.currentSystem'
}

run_full_derivation_checks() {
  local system check_name

  if [[ "$full_mode" != true ]]; then
    return 0
  fi

  system="$(current_system)"

  for check_name in \
    shellcheck \
    deadnix \
    statix \
    kanidm-admin-clippy \
    kanidm-admin-test \
    mail-archive-ui-test
  do
    echo "ℹ️ Running ${check_name} derivation…"
    nix build ".#checks.${system}.${check_name}" --no-link --print-build-logs
  done
}

run_shell_tests() {
  if [[ "$full_mode" == true ]]; then
    echo "ℹ️ Running full repository policy tests…"
    "${tests_dir}/run-script-tests.sh" --full
    return 0
  fi

  echo "ℹ️ Running lean repository policy tests…"
  "${tests_dir}/run-script-tests.sh"
}

if [[ "$skip_flake_check" == false ]]; then
  if [[ "$full_mode" == true || "$run_flake_check" == true ]]; then
    echo "ℹ️ Running flake checks (no build)…"
    nix flake check --no-build
    flake_check_completed=true
  fi
fi

run_full_derivation_checks
run_shell_tests

write_validation_stamp() {
  local archive_sha stamp_file created_epoch

  archive_sha="$(hash_deploy_repo_archive)"
  stamp_file="${validation_cache_dir}/${archive_sha}.json"
  created_epoch="$(date +%s)"

  mkdir -p "$validation_cache_dir"
  jq -n \
    --arg archiveSha256 "$archive_sha" \
    --argjson createdEpoch "$created_epoch" \
    '{
      archiveSha256: $archiveSha256,
      createdEpoch: $createdEpoch,
      flakeCheckSucceeded: true,
      checkRepoSucceeded: true
    }' >"$stamp_file"
}

if [[ "$flake_check_completed" == true ]]; then
  write_validation_stamp
fi

echo "✅ Repository checks passed."
