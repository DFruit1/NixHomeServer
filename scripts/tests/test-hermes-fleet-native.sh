#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  export PATH="/usr/bin:$PATH"
  exec python3 -B "$repo/scripts/hermes/fixture-runner.py" --repo "$repo" \
    --suite "$repo/scripts/tests/test-hermes-fleet-native.sh"
fi
scratch="$(mktemp -d)"
trap 'rm -r "$scratch"' EXIT
"$HERMES_FIXTURE_NATIVE_PYTHON" -B "$repo/scripts/tests/hermes-fleet-native.py" \
  --hermes-repo "$(dirname "$(dirname "$(dirname "$HERMES_FIXTURE_NATIVE_PYTHON")")")" --scratch "$scratch"
