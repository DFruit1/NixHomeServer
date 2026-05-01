#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg

echo "ℹ️ Checking validated deploy wrapper…"
forbid_match scripts/deploy-validated.sh 'nix flake check --no-build' \
  "deploy-validated.sh must not run local flake checks before deploy."
require_fixed scripts/deploy-validated.sh 'check_remote_build_host_storage "$build_host"' \
  "deploy-validated.sh must check free space on the configured build host."
require_fixed scripts/deploy-validated.sh 'run_remote_repo_checks "$build_host"' \
  "deploy-validated.sh must run repository checks on the remote build host."
require_fixed scripts/deploy-validated.sh 'nix shell nixpkgs#ripgrep nixpkgs#python3 -c ./scripts/check-repo.sh --full --skip-flake-check' \
  "deploy-validated.sh must bootstrap ripgrep and python3 for the exhaustive repo gate on the remote build host."
require_fixed scripts/deploy-validated.sh 'stage_archive_on_remote "$repo_archive" "$remote_host" "deploy-validated-repo"' \
  "deploy-validated.sh must upload the local checkout archive to the build host."
require_match scripts/deploy-validated.sh 'run_rebuild test' \
  "deploy-validated.sh must run nixos-rebuild test."
require_fixed scripts/deploy-validated.sh 'expected_lan_ip="$(nix_var '\''vars.serverLanIP'\'')"' \
  "deploy-validated.sh must evaluate vars.serverLanIP for transition-aware messaging."
require_fixed scripts/deploy-validated.sh 'Transition deploy: the current SSH/build endpoint differs from vars.serverLanIP.' \
  "deploy-validated.sh must emit a transition advisory when the current endpoint differs from vars.serverLanIP."
require_fixed scripts/deploy-validated.sh 'run_remote_runtime_readiness "$target_host"' \
  "deploy-validated.sh must invoke runtime-readiness.sh from a staged remote checkout when available on the target."
require_fixed scripts/deploy-validated.sh '--profile deploy' \
  "deploy-validated.sh must use the explicit deploy runtime-health profile."
require_match scripts/deploy-validated.sh 'if \[\[ "\$action" == "switch" \]\]' \
  "deploy-validated.sh must gate nixos-rebuild switch behind an explicit switch action."

echo "✅ Deploy wrapper tests passed."
