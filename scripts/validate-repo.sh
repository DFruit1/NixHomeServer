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
  - runs the lean script suite through scripts/tests/run-script-tests.sh
  - builds flake check derivations except repo-policy, which is run directly
  - runs the pinned Homepage Playwright end-to-end suite

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
  local system check_name check_names

  if [[ "$full_mode" != true ]]; then
    return 0
  fi

  system="$(current_system)"
  if ! check_names="$(
    nix eval --json ".#checks.${system}" --apply 'checks: builtins.attrNames checks' \
      | jq -r '.[]' \
      | sort
  )" || [[ -z "$check_names" ]]; then
    echo "❌ Could not evaluate a non-empty flake check worklist for ${system}." >&2
    exit 1
  fi

  while IFS= read -r check_name; do
    [[ -n "$check_name" ]] || continue
    [[ "$check_name" != "repo-policy" ]] || continue
    echo "ℹ️ Running ${check_name} derivation…"
    nix build ".#checks.${system}.${check_name}" --no-link --print-build-logs
  done <<<"$check_names"
}

run_shell_tests() {
  echo "ℹ️ Running repository policy tests…"
  "${tests_dir}/run-script-tests.sh"
}

run_full_e2e_checks() {
  if [[ "$full_mode" != true ]]; then
    return 0
  fi

  echo "ℹ️ Running Homepage Playwright end-to-end tests…"
  "$repo_root/scripts/test-homepage-ui.sh"
}

if [[ "$skip_flake_check" == false ]]; then
  if [[ "$full_mode" == true || "$run_flake_check" == true ]]; then
    echo "ℹ️ Running flake checks (no build)…"
    nix flake check --no-build
  fi
fi

run_full_derivation_checks
run_shell_tests
run_full_e2e_checks

echo "✅ Repository checks passed."
