#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/tests/run-script-tests.sh [--all-apps]

Run the lean repository checks used by routine rebuild validation.

By default, repository-wide optional-app tests are skipped. Use --all-apps to
test the complete application catalog, including apps not selected by the host.
EOF
}

all_apps=false
while (($# > 0)); do
  case "$1" in
    --all-apps)
      all_apps=true
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

# Flake derivation checks own package builds. Shell regression tests should
# inspect/evaluate generated outputs without redundantly building them.
export NIXHOMESERVER_SKIP_NESTED_BUILDS="${NIXHOMESERVER_SKIP_NESTED_BUILDS:-1}"
if [[ "$all_apps" == true ]]; then
  export NIXHOMESERVER_TEST_ALL_APPS=1
else
  export NIXHOMESERVER_TEST_ALL_APPS=0
fi

all_app_only_test() {
  case "${1##*/}" in
    test-app-module-structure.sh | \
    test-application-hardening.sh | \
    test-authorization-group-validation.sh | \
    test-beszel-module.sh | \
    test-chaptarr-module.sh | \
    test-kiwix-disable-evaluation.sh | \
    test-module-boundaries.sh | \
    test-module-disable-evaluation.sh | \
    test-module-removal-evaluation.sh | \
    test-paperless-v3-readiness.sh | \
    test-secret-definitions.sh | \
    test-secret-generation-flow.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

test_scripts=(
  scripts/tests/test-app-module-structure.sh
  scripts/tests/test-attic-cache.sh
  scripts/tests/test-kanidm-group-owned-access.sh
  scripts/tests/test-module-boundaries.sh
  scripts/tests/test-module-removal-evaluation.sh
  scripts/tests/test-module-disable-evaluation.sh
  scripts/tests/test-netbird-login-convergence.sh
  scripts/tests/test-nix-store-capacity-gc.sh
  scripts/tests/test-offline-media-reliability.sh
  scripts/tests/test-deploy-cli.sh
  scripts/tests/test-deploy-transaction-runtime.sh
  scripts/tests/test-evaluated-service-hardening.sh
  scripts/tests/test-data-pool-consumers.sh
  scripts/tests/test-public-route-check.sh
  scripts/tests/test-canary-render-check.sh
  scripts/tests/test-application-hardening.sh
  scripts/tests/test-archive-view-safety.sh
  scripts/tests/test-auth-gateway-logout.sh
  scripts/tests/test-authorization-group-validation.sh
  scripts/tests/test-beszel-module.sh
  scripts/tests/test-chaptarr-module.sh
  scripts/tests/test-backup-access-separation.sh
  scripts/tests/test-role-only-sftp-access.sh
  scripts/tests/test-bootstrap-zfs-guid-mode.sh
  scripts/tests/test-bootstrap-secret-preflight.sh
  scripts/tests/test-bootstrap-safety.sh
  scripts/tests/test-core-runtime-safety.sh
  scripts/tests/test-config-input-validation.sh
  scripts/tests/test-opinionated-vars.sh
  scripts/tests/test-decrypt-age-secrets.sh
  scripts/tests/test-export-inventory.sh
  scripts/tests/test-first-boot-convergence.sh
  scripts/tests/test-file-access-identity-derivation.sh
  scripts/tests/test-failure-alert-delivery.sh
  scripts/tests/test-freshrss-module.sh
  scripts/tests/test-freshness-marker.sh
  scripts/tests/test-homepage-guidance.sh
  scripts/tests/test-identity-reconcile-fail-closed.sh
  scripts/tests/test-integration-dependencies.sh
  scripts/tests/test-install-repository-seeding.sh
  scripts/tests/test-jellyfin-oidc.sh
  scripts/tests/test-kanidm-provision-validation.sh
  scripts/tests/test-kiwix-disable-evaluation.sh
  scripts/tests/test-kopia-cli-wrapper.sh
  scripts/tests/test-mail-archive-paperless-reliability.sh
  scripts/tests/test-media-manager-core.sh
  scripts/tests/test-paperless-v3-readiness.sh
  scripts/tests/test-mkvmaker-automation.sh
  scripts/tests/test-mkvmaker-distributed-queue.sh
  scripts/tests/test-mkvmaker-worker-image.sh
  scripts/tests/test-platform-storage-profiles.sh
  scripts/tests/test-runtime-reliability.sh
  scripts/tests/test-rclone-safety.sh
  scripts/tests/test-rclone-mega-capacity-check.sh
  scripts/tests/test-rclone-mega-preflight.sh
  scripts/tests/test-script-test-runner.sh
  scripts/tests/test-smart-sweep-runtime.sh
  scripts/tests/test-storage-path-validation.sh
  scripts/tests/test-unbound-adblock.sh
  scripts/tests/test-zfs-pool-identity.sh
  scripts/tests/test-zfs-snapshot-freshness.sh
  scripts/tests/test-secret-definitions.sh
  scripts/tests/test-secret-generation-flow.sh
)

active=0
max_jobs=$(nproc 2>/dev/null || echo 2)
failures=0
test_tmp="${TMPDIR:-/tmp}/nixhomeserver-tests"
mkdir -p "$test_tmp"

wait_for_one_test() {
  if ! wait -n 2>/dev/null; then
    ((failures++)) || true
  fi
  ((active--)) || true
}

for test_script in "${test_scripts[@]}"; do
  if [[ "$all_apps" != true ]] && all_app_only_test "$test_script"; then
    printf '==> %s (skipped: use --all-apps)\n' "$test_script"
    continue
  fi

  while (( active >= max_jobs )); do
    wait_for_one_test
  done

  log_file="${test_tmp}/test-${test_script//\//_}.log"
  (
    printf '==> %s\n' "$test_script"
    if ! bash "$test_script" > "$log_file" 2>&1; then
      cat "$log_file"
      exit 1
    fi
  ) &
  ((active++)) || true
done

while (( active > 0 )); do
  wait_for_one_test
done

if (( failures > 0 )); then
  echo "❌ $failures test script(s) failed."
  exit 1
fi

echo "✅ All requested script tests passed."
