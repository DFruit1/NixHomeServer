#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/tests/run-script-tests.sh

Run the lean repository checks used by routine rebuild validation.
EOF
}

while (($# > 0)); do
  case "$1" in
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
  scripts/tests/test-app-module-structure.sh
  scripts/tests/test-module-boundaries.sh
  scripts/tests/test-deploy-cli.sh
  scripts/tests/test-public-route-check.sh
  scripts/tests/test-export-inventory.sh
  scripts/tests/test-platform-storage-profiles.sh
  scripts/tests/test-runtime-reliability.sh
  scripts/tests/test-secret-definitions.sh
)

for test_script in "${test_scripts[@]}"; do
  bash "$test_script"
done

echo "✅ All requested script tests passed."
