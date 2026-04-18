#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg

echo "ℹ️ Checking validated deploy wrapper…"
require_fixed scripts/deploy-validated.sh 'nix flake check --no-build' \
  "deploy-validated.sh must run flake checks before deploy."
require_fixed scripts/deploy-validated.sh '"$repo_root/scripts/check-repo.sh"' \
  "deploy-validated.sh must run scripts/check-repo.sh before deploy."
require_match scripts/deploy-validated.sh 'run_rebuild test' \
  "deploy-validated.sh must run nixos-rebuild test."
require_fixed scripts/deploy-validated.sh 'runtime-readiness.sh' \
  "deploy-validated.sh must invoke runtime-readiness.sh when available on the target."
require_match scripts/deploy-validated.sh 'if \[\[ "\$action" == "switch" \]\]' \
  "deploy-validated.sh must gate nixos-rebuild switch behind an explicit switch action."

echo "✅ Deploy wrapper tests passed."
