#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

for test_script in \
  tests/backup-target.sh \
  tests/check-repo-runner.sh \
  tests/module-imports.sh \
  tests/deploy-wrapper.sh \
  tests/disko-wrappers.sh \
  tests/runtime-readiness.sh \
  tests/runtime-health-report.sh \
  tests/secrets.sh \
  tests/storage-layout-audit.sh \
  tests/storage-monitoring.sh \
  tests/core-config-base.sh \
  tests/core-config-storage.sh \
  tests/core-config-apps.sh
do
  "$test_script"
done

echo "✅ All requested tests passed."
