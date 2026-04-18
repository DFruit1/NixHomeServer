#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

for test_script in \
  tests/bootstrap-readiness.sh \
  tests/module-imports.sh \
  tests/deploy-wrapper.sh \
  tests/secrets.sh \
  tests/core-config.sh
do
  "$test_script"
done

echo "✅ All requested tests passed."
