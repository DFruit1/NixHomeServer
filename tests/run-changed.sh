#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

base_ref=""

while (($# > 0)); do
  case "$1" in
    --base-ref)
      if (($# < 2)) || [[ -z "${2:-}" ]]; then
        echo "❌ --base-ref requires a revision argument." >&2
        exit 1
      fi
      base_ref="${2:-}"
      shift 2
      ;;
    -h|--help)
      cat <<'EOF'
Usage: tests/run-changed.sh [--base-ref <rev>]

Run the local smoke suite plus targeted tests based on changed files.
Falls back to tests/run-all.sh when change detection is unavailable.
EOF
      exit 0
      ;;
    *)
      echo "❌ Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

collect_changed_files() {
  local diff_output untracked_output

  if [[ -n "${RUN_CHANGED_FORCE_FILES_FILE:-}" ]]; then
    cat "${RUN_CHANGED_FORCE_FILES_FILE}"
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

run_test() {
  local test_script="$1"

  if [[ -n "${RUN_CHANGED_LOG_FILE:-}" ]]; then
    printf '%s\n' "$test_script" >>"${RUN_CHANGED_LOG_FILE}"
    return 0
  fi

  "$test_script"
}

run_smoke_suite() {
  run_test tests/module-imports.sh
  run_test tests/deploy-wrapper.sh
  run_test tests/secrets.sh
  run_test tests/runtime-readiness.sh
  run_test tests/storage-monitoring.sh
  run_test tests/core-config-base.sh
}

matches_changed_files() {
  local changed_files="$1"
  local pattern="$2"
  rg -q "$pattern" <<<"$changed_files"
}

changed_files=""
if ! changed_files="$(collect_changed_files)"; then
  echo "ℹ️ Change detection unavailable; falling back to the full test suite."
  if [[ -n "${RUN_CHANGED_LOG_FILE:-}" ]]; then
    printf '%s\n' "tests/run-all.sh" >>"${RUN_CHANGED_LOG_FILE}"
    exit 0
  fi
  tests/run-all.sh
  exit 0
fi

run_smoke_suite

if matches_changed_files "$changed_files" '^(scripts/audit-storage-layout\.sh$|modules/Core_Modules/storage/layout\.nix$|tests/storage-layout-audit\.sh$)'; then
  run_test tests/storage-layout-audit.sh
fi

if matches_changed_files "$changed_files" '^(scripts/(runtime-readiness|runtime-health-report|storage-health-report|lib-runtime-health)\.sh$|modules/Core_Modules/storage-monitoring/default\.nix$|tests/(runtime-readiness|runtime-health-report|storage-monitoring)\.sh$)'; then
  run_test tests/runtime-health-report.sh
fi

if matches_changed_files "$changed_files" '^(configuration\.nix$|vars\.nix$|flake\.nix$|scripts/lib-storage-health\.sh$|modules/Core_Modules/(storage|impermanence|restic-state)/|tests/core-config-storage\.sh$)'; then
  run_test tests/core-config-storage.sh
fi

if matches_changed_files "$changed_files" '^(scripts/check-repo\.sh$|tests/run-(all|changed)\.sh$|tests/check-repo-runner\.sh$|scripts/check-docs\.sh$|tests/manual-docs\.sh$)'; then
  run_test tests/check-repo-runner.sh
fi

if matches_changed_files "$changed_files" '^(configuration\.nix$|vars\.nix$|flake\.nix$|modules/|rust/apps/(mail-archive-ui|kanidm-admin)/|tests/core-config-apps\.sh$)'; then
  run_test tests/core-config-apps.sh
fi

echo "✅ Selected tests passed."
