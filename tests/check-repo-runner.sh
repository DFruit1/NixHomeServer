#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools mktemp rg

echo "ℹ️ Checking change-aware test selection…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

changed_files_file="${tmpdir}/changed-files.txt"
selection_log="${tmpdir}/selection.log"

run_selection_case() {
  local label="$1"
  local changed_content="$2"
  shift 2

  printf '%s\n' "$changed_content" >"$changed_files_file"
  : >"$selection_log"

  RUN_CHANGED_FORCE_FILES_FILE="$changed_files_file" \
    RUN_CHANGED_LOG_FILE="$selection_log" \
    tests/run-changed.sh >/tmp/run-changed.out

  while (($# > 0)); do
    local mode="$1"
    local test_name="$2"
    shift 2

    if [[ "$mode" == "require" ]]; then
      require_fixed "$selection_log" "$test_name" "${label} must run ${test_name}."
    else
      forbid_match "$selection_log" "^${test_name}\$" "${label} must not run ${test_name}."
    fi
  done
}

run_selection_case \
  "Docs-only changes" \
  "documentation/operations.md" \
  require "tests/module-imports.sh" \
  require "tests/deploy-wrapper.sh" \
  require "tests/secrets.sh" \
  require "tests/runtime-readiness.sh" \
  require "tests/storage-monitoring.sh" \
  require "tests/core-config-base.sh" \
  forbid "tests/backup-target.sh" \
  forbid "tests/disko-wrappers.sh" \
  forbid "tests/storage-layout-audit.sh" \
  forbid "tests/core-config-storage.sh" \
  forbid "tests/core-config-apps.sh" \
  forbid "tests/check-repo-runner.sh"

run_selection_case \
  "Paperless module changes" \
  "modules/paperless/service.nix" \
  require "tests/storage-monitoring.sh" \
  require "tests/core-config-apps.sh" \
  forbid "tests/backup-target.sh" \
  forbid "tests/disko-wrappers.sh" \
  forbid "tests/core-config-storage.sh"

run_selection_case \
  "Storage and Disko changes" \
  "modules/Core_Modules/storage/default.nix
disko.nix" \
  require "tests/storage-monitoring.sh" \
  require "tests/core-config-storage.sh" \
  forbid "tests/storage-layout-audit.sh" \
  forbid "tests/backup-target.sh" \
  forbid "tests/disko-wrappers.sh"

run_selection_case \
  "Backup target changes" \
  "scripts/backup-target.sh" \
  require "tests/storage-monitoring.sh" \
  forbid "tests/core-config-storage.sh" \
  forbid "tests/backup-target.sh" \
  forbid "tests/disko-wrappers.sh"

run_selection_case \
  "Restore guide changes" \
  "documentation/restore-and-recovery.md" \
  require "tests/storage-monitoring.sh" \
  forbid "tests/disko-wrappers.sh" \
  forbid "tests/core-config-apps.sh" \
  forbid "tests/check-repo-runner.sh"

run_selection_case \
  "Runtime monitoring changes" \
  "scripts/runtime-health-report.sh
modules/Core_Modules/storage-monitoring/default.nix" \
  require "tests/storage-monitoring.sh" \
  require "tests/runtime-health-report.sh" \
  forbid "tests/backup-target.sh" \
  forbid "tests/disko-wrappers.sh"

run_selection_case \
  "Configuration changes" \
  "configuration.nix" \
  require "tests/storage-monitoring.sh" \
  require "tests/core-config-storage.sh" \
  require "tests/core-config-apps.sh" \
  forbid "tests/backup-target.sh" \
  forbid "tests/disko-wrappers.sh"

run_selection_case \
  "Runner changes" \
  "scripts/check-repo.sh" \
  require "tests/check-repo-runner.sh"

echo "ℹ️ Checking run-changed fallback behavior…"
cat >"${tmpdir}/bin-git" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "${tmpdir}/bin-git"
mkdir -p "${tmpdir}/bin"
mv "${tmpdir}/bin-git" "${tmpdir}/bin/git"

: >"$selection_log"
PATH="${tmpdir}/bin:$PATH" \
  RUN_CHANGED_LOG_FILE="$selection_log" \
  tests/run-changed.sh >/tmp/run-changed-fallback.out
require_fixed "$selection_log" "tests/run-all.sh" \
  "run-changed must fall back to tests/run-all.sh when git-based change detection fails."

echo "ℹ️ Checking check-repo runner modes…"
runner_dir="${tmpdir}/runner-tests"
mkdir -p "$runner_dir" "${tmpdir}/bin-check-repo"
runner_log="${tmpdir}/check-repo.log"

cat >"${runner_dir}/run-all.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'run-all\n' >>"$runner_log"
EOF
chmod +x "${runner_dir}/run-all.sh"

cat >"${runner_dir}/run-changed.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'run-changed %s\n' "\$*" >>"$runner_log"
EOF
chmod +x "${runner_dir}/run-changed.sh"

cat >"${tmpdir}/bin-check-repo/nix" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'nix %s\n' "\$*" >>"$runner_log"
if [[ "\$1" == "eval" ]]; then
  printf 'x86_64-linux\n'
fi
EOF
chmod +x "${tmpdir}/bin-check-repo/nix"

cat >"${tmpdir}/bin-check-repo/git" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  rev-parse)
    printf '/tmp/repo\n'
    ;;
  diff)
    printf 'modules/mail-archive-ui/default.nix\n'
    ;;
  ls-files)
    exit 0
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "${tmpdir}/bin-check-repo/git"

: >"$runner_log"
PATH="${tmpdir}/bin-check-repo:$PATH" \
  CHECK_REPO_TESTS_DIR="$runner_dir" \
  scripts/check-repo.sh >/tmp/check-repo-default.out
require_fixed "$runner_log" 'nix flake check --no-build' \
  "Default check-repo mode must run flake checks."
require_fixed "$runner_log" 'nix build .#checks.x86_64-linux.mail-archive-ui-test --print-build-logs' \
  "Default check-repo mode must build the targeted mail-archive UI test derivation."
forbid_match "$runner_log" 'kanidm-admin-(clippy|test)' \
  "Default check-repo mode must skip unrelated Rust derivations."
require_fixed "$runner_log" 'run-changed ' \
  "Default check-repo mode must invoke tests/run-changed.sh."
forbid_match "$runner_log" '^run-all$' \
  "Default check-repo mode must not invoke the exhaustive shell suite."

: >"$runner_log"
PATH="${tmpdir}/bin-check-repo:$PATH" \
  CHECK_REPO_TESTS_DIR="$runner_dir" \
  scripts/check-repo.sh --full >/tmp/check-repo-full.out
require_fixed "$runner_log" 'nix flake check --no-build' \
  "Full check-repo mode must run flake checks."
require_fixed "$runner_log" 'nix build .#checks.x86_64-linux.kanidm-admin-clippy --print-build-logs' \
  "Full check-repo mode must build the kanidm-admin clippy derivation."
require_fixed "$runner_log" 'nix build .#checks.x86_64-linux.kanidm-admin-test --print-build-logs' \
  "Full check-repo mode must build the kanidm-admin test derivation."
require_fixed "$runner_log" 'nix build .#checks.x86_64-linux.mail-archive-ui-test --print-build-logs' \
  "Full check-repo mode must build the mail-archive UI test derivation."
require_fixed "$runner_log" 'run-all' \
  "Full check-repo mode must invoke tests/run-all.sh."

: >"$runner_log"
PATH="${tmpdir}/bin-check-repo:$PATH" \
  CHECK_REPO_TESTS_DIR="$runner_dir" \
  scripts/check-repo.sh --full --skip-flake-check >/tmp/check-repo-skip.out
forbid_match "$runner_log" 'flake check --no-build' \
  "Skipping flake checks must suppress the flake-check invocation only."
require_fixed "$runner_log" 'run-all' \
  "Skipping flake checks must still run the exhaustive shell suite."

echo "✅ Check-repo runner tests passed."
