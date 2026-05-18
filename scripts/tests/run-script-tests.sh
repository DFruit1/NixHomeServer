#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

for test_script in \
  scripts/tests/test-secret-definitions.sh \
  scripts/tests/test-deploy-with-validation-remote-preflight.sh \
  scripts/tests/test-rebuild-remote-fast.sh \
  scripts/tests/test-storage-health-checks.sh \
  scripts/tests/test-storage-device-discovery.sh \
  scripts/tests/test-upload-processor.sh \
  scripts/tests/test-runtime-readiness.sh \
  scripts/tests/test-system-health-report.sh \
  scripts/tests/test-evaluated-host-config.sh
do
  bash "$test_script"
done

echo "✅ All requested script tests passed."
