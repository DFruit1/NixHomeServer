#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/tests/run-script-tests.sh [--full]

Default mode runs the lean repository checks used by routine rebuild
validation. Use --full for the broader script and evaluated-config suite.
EOF
}

full_mode=false

while (($# > 0)); do
  case "$1" in
    --full)
      full_mode=true
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

test_scripts=(
  scripts/tests/test-secret-definitions.sh
  scripts/tests/test-deploy-with-validation-remote-preflight.sh
  scripts/tests/test-rebuild-remote-fast.sh
  scripts/tests/test-runtime-readiness.sh
)

if [[ "$full_mode" == true ]]; then
  test_scripts+=(
    scripts/tests/test-storage-health-checks.sh
    scripts/tests/test-storage-device-discovery.sh
    scripts/tests/test-upload-processor.sh
    scripts/tests/test-system-health-report.sh
    scripts/tests/test-evaluated-host-config.sh
  )
fi

for test_script in "${test_scripts[@]}"; do
  bash "$test_script"
done

echo "✅ All requested script tests passed."
