#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

include_runtime=0

for arg in "$@"; do
  case "$arg" in
    --with-runtime)
      include_runtime=1
      ;;
    *)
      echo "Usage: tests/run-all.sh [--with-runtime]"
      exit 1
      ;;
  esac
done

for test_script in \
  tests/bootstrap-readiness.sh \
  tests/apparmor.sh \
  tests/auth-routing.sh \
  tests/firewall.sh \
  tests/networking.sh \
  tests/runtime-contracts.sh \
  tests/secrets.sh
do
  "$test_script"
done

if (( include_runtime )); then
  tests/dietpi.sh
fi

echo "✅ All requested tests passed."
