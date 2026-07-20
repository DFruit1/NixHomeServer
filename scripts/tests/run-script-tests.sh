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
  scripts/tests/test-module-removal-evaluation.sh
  scripts/tests/test-module-disable-evaluation.sh
  scripts/tests/test-netbird-login-convergence.sh
  scripts/tests/test-offline-media-reliability.sh
  scripts/tests/test-deploy-cli.sh
  scripts/tests/test-deploy-transaction-runtime.sh
  scripts/tests/test-data-pool-consumers.sh
  scripts/tests/test-public-route-check.sh
  scripts/tests/test-canary-render-check.sh
  scripts/tests/test-application-hardening.sh
  scripts/tests/test-archive-view-safety.sh
  scripts/tests/test-authorization-group-validation.sh
  scripts/tests/test-backup-access-separation.sh
  scripts/tests/test-role-only-sftp-access.sh
  scripts/tests/test-bootstrap-zfs-guid-mode.sh
  scripts/tests/test-bootstrap-recovery-guards.sh
  scripts/tests/test-bootstrap-secret-preflight.sh
  scripts/tests/test-bootstrap-safety.sh
  scripts/tests/test-core-runtime-safety.sh
  scripts/tests/test-config-input-validation.sh
  scripts/tests/test-decrypt-age-secrets.sh
  scripts/tests/test-export-inventory.sh
  scripts/tests/test-first-boot-convergence.sh
  scripts/tests/test-file-access-identity-derivation.sh
  scripts/tests/test-freshness-marker.sh
  scripts/tests/test-homepage-guidance.sh
  scripts/tests/test-identity-reconcile-fail-closed.sh
  scripts/tests/test-install-repository-seeding.sh
  scripts/tests/test-kanidm-provision-validation.sh
  scripts/tests/test-kiwix-disable-evaluation.sh
  scripts/tests/test-kopia-cli-wrapper.sh
  scripts/tests/test-platform-storage-profiles.sh
  scripts/tests/test-runtime-reliability.sh
  scripts/tests/test-rclone-safety.sh
  scripts/tests/test-smart-sweep-runtime.sh
  scripts/tests/test-storage-path-validation.sh
  scripts/tests/test-zfs-pool-identity.sh
  scripts/tests/test-zfs-snapshot-freshness.sh
  scripts/tests/test-secret-definitions.sh
  scripts/tests/test-secret-generation-flow.sh
)

for test_script in "${test_scripts[@]}"; do
  printf '==> %s\n' "$test_script"
  bash "$test_script"
done

echo "✅ All requested script tests passed."
