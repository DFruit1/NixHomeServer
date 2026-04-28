#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/lib-repo.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/check-repo.sh [--full] [--skip-flake-check] [--base-ref <rev>]

Run the local repository validation gate.

Default mode:
  - runs `nix flake check --no-build`
  - runs change-aware shell tests through tests/run-changed.sh
  - builds targeted Rust checks only when relevant files changed

Full mode:
  - runs `nix flake check --no-build` unless --skip-flake-check is used
  - runs the exhaustive shell suite through tests/run-all.sh
  - builds all explicit Rust check derivations

Examples:
  scripts/check-repo.sh
  scripts/check-repo.sh --full
  scripts/check-repo.sh --full --skip-flake-check
  scripts/check-repo.sh --base-ref origin/main
EOF
}

full_mode=false
skip_flake_check=false
base_ref=""
tests_dir="${CHECK_REPO_TESTS_DIR:-$repo_root/tests}"

while (($# > 0)); do
  case "$1" in
    --full)
      full_mode=true
      shift
      ;;
    --skip-flake-check)
      skip_flake_check=true
      shift
      ;;
    --base-ref)
      if (($# < 2)) || [[ -z "${2:-}" ]]; then
        echo "❌ --base-ref requires a revision argument." >&2
        exit 1
      fi
      base_ref="${2:-}"
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

need nix

current_system() {
  nix eval --impure --raw --expr 'builtins.currentSystem'
}

collect_changed_files() {
  local diff_output untracked_output

  if [[ -n "${CHECK_REPO_FORCE_CHANGED_FILES_FILE:-}" ]]; then
    cat "${CHECK_REPO_FORCE_CHANGED_FILES_FILE}"
    return 0
  fi

  if ! command -v git >/dev/null 2>&1; then
    return 1
  fi

  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    return 1
  fi

  if [[ -n "$base_ref" ]]; then
    diff_output="$(git diff --name-only --relative "${base_ref}...HEAD" 2>/dev/null)" || return 1
  else
    diff_output="$(git diff --name-only --relative HEAD 2>/dev/null)" || return 1
  fi

  untracked_output="$(git ls-files --others --exclude-standard 2>/dev/null)" || return 1

  {
    printf '%s\n' "$diff_output"
    printf '%s\n' "$untracked_output"
  } | awk 'NF' | sort -u
}

should_run_rust_check() {
  local check_name="$1"
  local changed_files="$2"

  if [[ "$full_mode" == true ]]; then
    return 0
  fi

  case "$check_name" in
    kanidm-admin-clippy|kanidm-admin-test)
      rg -q '^(rust/apps/kanidm-admin/|flake\.nix$)' <<<"$changed_files"
      ;;
    mail-archive-ui-test)
      rg -q '^(rust/apps/mail-archive-ui/|modules/mail-archive-ui/|modules/mail-archive-paperless/|flake\.nix$)' <<<"$changed_files"
      ;;
    *)
      return 1
      ;;
  esac
}

run_rust_checks() {
  local changed_files="$1"
  local system check_name

  system="$(current_system)"

  for check_name in \
    kanidm-admin-clippy \
    kanidm-admin-test \
    mail-archive-ui-test
  do
    if should_run_rust_check "$check_name" "$changed_files"; then
      echo "ℹ️ Running ${check_name} derivation…"
      nix build ".#checks.${system}.${check_name}" --print-build-logs
    fi
  done
}

run_shell_tests() {
  if [[ "$full_mode" == true ]]; then
    echo "ℹ️ Running full repository policy tests…"
    "${tests_dir}/run-all.sh"
    return 0
  fi

  echo "ℹ️ Running change-aware repository policy tests…"
  if [[ -n "$base_ref" ]]; then
    "${tests_dir}/run-changed.sh" --base-ref "$base_ref"
  else
    "${tests_dir}/run-changed.sh"
  fi
}

if [[ "$skip_flake_check" == false ]]; then
  echo "ℹ️ Running flake checks (no build)…"
  nix flake check --no-build
fi

changed_files=""
if [[ "$full_mode" == false ]]; then
  if ! changed_files="$(collect_changed_files)"; then
    echo "ℹ️ Change detection unavailable; falling back to full validation."
    full_mode=true
  fi
fi

run_rust_checks "$changed_files"
run_shell_tests

echo "✅ Repository checks passed."
