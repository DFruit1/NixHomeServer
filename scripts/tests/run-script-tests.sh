#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

usage() {
  cat <<'EOF'
Usage: scripts/tests/run-script-tests.sh [--all-apps] [--full]

Run the repository checks used by routine rebuild validation.

By default, repository-wide optional-app tests are skipped. Use --all-apps to
test the complete application catalog, including apps not selected by the host.

Use --full to include heavy evaluation tests (runtime reliability, deploy
transaction, first-boot convergence, secret generation, kopia wrapper).
EOF
}

all_apps=false
full_mode=false
while (($# > 0)); do
  case "$1" in
    --all-apps)
      all_apps=true
      shift
      ;;
    --full)
      full_mode=true
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

# The Hermes policy tests import PyYAML directly or through the installers
# they exercise. A delegated worker's terminal resolves python3 to Hermes'
# managed runtime, which does not ship PyYAML; without this preflight that
# surfaces as many unrelated ModuleNotFoundError failures instead of one
# actionable message (2026-10-19: eight policy tests red for one cause).
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
  echo "❌ PyYAML is unavailable to the resolved python3: $(command -v python3 || echo 'not found')" >&2
  echo "   Repository script tests import yaml. Install PyYAML for that interpreter" >&2
  echo "   (e.g. 'python3 -m pip install pyyaml', or transplant the distro package" >&2
  echo "   into the interpreter's site-packages when pip has no reachable index)." >&2
  exit 1
fi

all_app_only_test() {
  case "${1##*/}" in
    test-module-structure.sh | \
    test-application-hardening.sh | \
    test-authorization-group-validation.sh | \
    test-chaptarr-module.sh | \
    test-kiwix-disable-evaluation.sh | \
    test-module-removal-evaluation.sh | \
    test-paperless-v3-readiness.sh | \
    test-search-module.sh | \
    test-secret-structure.sh | \
    test-secret-generation.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

lean_skip_test() {
  case "${1##*/}" in
    test-runtime-reliability.sh | \
    test-deploy-transaction-runtime.sh | \
    test-first-boot-convergence.sh | \
    test-secret-generation.sh | \
    test-kopia-cli-wrapper.sh | \
    test-module-disable-evaluation.sh)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

test_scripts=(
  scripts/tests/test-hermes-opencode-acp.sh
  scripts/tests/test-hermes-cron-policy.sh
  scripts/tests/test-hermes-memory-policy.sh
  scripts/tests/test-hermes-worker-policy.sh
  scripts/tests/test-hermes-autonomy.sh
  scripts/tests/test-hermes-autonomy-runtime.sh
  scripts/tests/test-hermes-fixture-isolation.sh
  scripts/tests/test-hermes-capability-recovery.sh
  scripts/tests/test-hermes-aging-escalation.sh
  scripts/tests/test-hermes-analytics.sh
  scripts/tests/test-module-structure.sh
  scripts/tests/test-langfuse-secrets.sh
  scripts/tests/test-langfuse-module.sh
  scripts/tests/test-searxng-module.sh
  scripts/tests/test-ntfy-module.sh
  scripts/tests/test-attic-cache.sh
  scripts/tests/test-kanidm-group-owned-access.sh
  scripts/tests/test-module-removal-evaluation.sh
  scripts/tests/test-module-disable-evaluation.sh
  scripts/tests/test-netbird-login-convergence.sh
  scripts/tests/test-ipfs-swarm-binding.sh
  scripts/tests/test-nix-store-capacity-gc.sh
  scripts/tests/test-disk-space-cleanup.sh
  scripts/tests/test-temp-cleanup.sh
  scripts/tests/test-install-temp-cleanup.sh
  scripts/tests/test-temp-cleanup-module.sh
  scripts/tests/test-shutdown-guard.sh
  scripts/tests/test-offline-media-reliability.sh
  scripts/tests/test-opencloud-module.sh
  scripts/tests/test-opencloud-public-access.sh
  scripts/tests/test-deploy-cli.sh
  scripts/tests/test-deploy-archive-staging.sh
  scripts/tests/test-deploy-debug-attestation.sh
  scripts/tests/test-deploy-transaction-runtime.sh
  scripts/tests/test-build-allocation-policy.sh
  scripts/tests/test-evaluated-service-hardening.sh
  scripts/tests/test-central-memory-containment.sh
  scripts/tests/test-data-pool-consumers.sh
  scripts/tests/test-public-route-check.sh
  scripts/tests/test-cloudflare-dns-sync.sh
  scripts/tests/test-canary-render-check.sh
  scripts/tests/test-canary-target-coverage.sh
  scripts/tests/test-application-hardening.sh
  scripts/tests/test-archive-view-safety.sh
  scripts/tests/test-auth-gateway-logout.sh
  scripts/tests/test-auth-gateway-session.sh
  scripts/tests/test-authorization-group-validation.sh
  scripts/tests/test-chaptarr-module.sh
  scripts/tests/test-backup-access-separation.sh
  scripts/tests/test-role-only-sftp-access.sh
  scripts/tests/test-bootstrap-zfs-guid-mode.sh
  scripts/tests/test-bootstrap-secret-preflight.sh
  scripts/tests/test-bootstrap-safety.sh
  scripts/tests/test-browsertrix-downloader-module.sh
  scripts/tests/test-search-module.sh
  scripts/tests/test-core-runtime-safety.sh
  scripts/tests/test-local-admin-sudo-policy.sh
  scripts/tests/test-config-input-validation.sh
  scripts/tests/test-opinionated-vars.sh
  scripts/tests/test-decrypt-age-secrets.sh
  scripts/tests/test-export-inventory.sh
  scripts/tests/test-first-boot-convergence.sh
  scripts/tests/test-file-access-identity-derivation.sh
  scripts/tests/test-failure-alert-delivery.sh
  scripts/tests/test-freshrss-module.sh
  scripts/tests/test-freshness-marker.sh
  scripts/tests/test-rust-workspace-dependencies.sh
  scripts/tests/test-rust-source-isolation.sh
  scripts/tests/test-rust-dependency-manifest-scope.sh
  scripts/tests/test-frontend-build-isolation.sh
  scripts/tests/test-nix-eval-cache.sh
  scripts/tests/test-remote-eval-helper.sh
  scripts/tests/test-remote-build-helper.sh
  scripts/tests/test-remote-run-helper.sh
  scripts/tests/test-reap-kanban-worktrees.sh
  scripts/tests/test-hermes-workspace-preflight.sh
  scripts/tests/test-hermes-workspace-repair.sh
  scripts/tests/test-hermes-worker-origin.sh
  scripts/tests/test-hermes-recovered-resume.sh
  scripts/tests/test-kanban-board-health.sh
  scripts/tests/test-quiescence-inventory.sh
  scripts/tests/test-kanban-retry-breaker.sh
  scripts/tests/test-kanban-durability-sync.sh
  scripts/tests/test-kanban-install-board-wiring.sh
  scripts/tests/test-kanban-decision-reply.sh
  scripts/tests/test-hermes-review-taskforce.sh
  scripts/tests/test-hermes-instruction-policy.sh
  scripts/tests/test-hermes-installer-convergence.sh
  scripts/tests/test-hermes-behavior-trials.sh
  scripts/tests/test-hermes-config-policy.sh
  scripts/tests/test-hermes-performance.sh
  scripts/tests/test-hermes-runtime-evidence.sh
  scripts/tests/test-hermes-blockers.sh
  scripts/tests/test-hermes-prerequisite-repair.sh
  scripts/tests/test-hermes-deploy-receipt.sh
  scripts/tests/test-hermes-coordination.sh
  scripts/tests/test-kanban-owner-alerts.sh
  scripts/tests/test-simplex-decisions.sh
  scripts/tests/test-hermes-owner-chat-policy.sh
  scripts/tests/test-steward-readonly.sh
  scripts/tests/test-steward-opportunity-scan.sh
  scripts/tests/test-auth-gateway-compression.sh
  scripts/tests/test-app-registration.sh
  scripts/tests/test-shell-template.sh
  scripts/tests/test-validation-build-checks.sh
  scripts/tests/test-frontend-package-independence.sh
  scripts/tests/test-node-pnpm-deps-scoping.sh
  scripts/tests/test-homepage-guidance.sh
  scripts/tests/test-homepage-vault.sh
  scripts/tests/test-portal-landing.sh
  scripts/tests/test-identity-reconcile-fail-closed.sh
  scripts/tests/test-integration-dependencies.sh
  scripts/tests/test-install-repository-seeding.sh
  scripts/tests/test-bootstrap-host.sh
  scripts/tests/test-sync-upstream.sh
  scripts/tests/test-jellyfin-oidc.sh
  scripts/tests/test-kanidm-branding.sh
  scripts/tests/test-kanidm-provision-validation.sh
  scripts/tests/test-kiwix-disable-evaluation.sh
  scripts/tests/test-kiwix-web-archives-integration.sh
  scripts/tests/test-kopia-cli-wrapper.sh
  scripts/tests/test-mail-archive-paperless-reliability.sh
  scripts/tests/test-media-manager-core.sh
  scripts/tests/test-paperless-v3-readiness.sh
  scripts/tests/test-ai-gate.sh
  scripts/tests/test-ai-tools-module.sh
  scripts/tests/test-ai-tools-office-helper.sh
  scripts/tests/test-gpu-power-limit.sh
  scripts/tests/test-background-qwen-split.sh
  scripts/tests/test-qwen-ai-tools-mcp-bridge.sh
  scripts/tests/test-mkvmaker-automation.sh
  scripts/tests/test-mkvmaker-tool-resolution.sh
  scripts/tests/test-platform-storage-profiles.sh
  scripts/tests/test-runtime-reliability.sh
  scripts/tests/test-model-artifact-storage.sh
  scripts/tests/test-rclone-safety.sh
  scripts/tests/test-rclone-mega-capacity-check.sh
  scripts/tests/test-rclone-mega-preflight.sh
  scripts/tests/test-storage-capacity-check.sh
  scripts/tests/test-script-test-runner.sh
  scripts/tests/test-smart-sweep-runtime.sh
  scripts/tests/test-storage-path-validation.sh
  scripts/tests/test-unbound-adblock.sh
  scripts/tests/test-edge-flood-protection.sh
  scripts/tests/test-vaultwarden-version.sh
  scripts/tests/test-zfs-pool-identity.sh
  scripts/tests/test-zfs-snapshot-freshness.sh
  scripts/tests/test-secret-structure.sh
  scripts/tests/test-secret-generation.sh
  scripts/tests/test-forgejo-mirror-grants.sh
)

NIXHOMESERVER_DEFAULT_HOST="$(test_default_host)"
export NIXHOMESERVER_DEFAULT_HOST

fixture_origin_pinned=false
fixture_helper="${HERMES_ROOT:-${HOME}/.hermes}/scripts/fixture-runner.py"
for origin_var in HERMES_KANBAN_TASK HERMES_KANBAN_DB HERMES_KANBAN_BOARD \
                  HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK \
                  HERMES_DELEGATED_CHILD_CONTEXT HERMES_PROFILE_NAME HERMES_PROFILE; do
  if [[ -n "${!origin_var:-}" ]]; then
    fixture_origin_pinned=true
    break
  fi
done

fixture_suite() {
  case "${1##*/}" in
    test-kanban-owner-alerts.sh | test-steward-readonly.sh | \
    test-steward-opportunity-scan.sh | test-kanban-retry-breaker.sh | \
    test-hermes-autonomy.sh | test-hermes-autonomy-runtime.sh | \
    test-hermes-worker-origin.sh | test-hermes-recovered-resume.sh) return 0 ;;
    *) return 1 ;;
  esac
}

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

  if [[ "$full_mode" != true ]] && lean_skip_test "$test_script"; then
    printf '==> %s (skipped: use --full)\n' "$test_script"
    continue
  fi

  while (( active >= max_jobs )); do
    wait_for_one_test
  done

  log_file="${test_tmp}/test-${test_script//\//_}.log"
  (
    printf '==> %s\n' "$test_script"
    if [[ "$fixture_origin_pinned" == true ]] && fixture_suite "$test_script"; then
      python3 -B "$fixture_helper" --repo "$TESTS_REPO_ROOT" \
        --suite "$TESTS_REPO_ROOT/$test_script" --timeout 300 > "$log_file" 2>&1 || {
        echo "❌ $test_script failed in required confined fixture; output follows:" >&2
        cat "$log_file" >&2
        exit 1
      }
    elif ! bash "$test_script" > "$log_file" 2>&1; then
      echo "❌ $test_script failed; output follows:" >&2
      cat "$log_file" >&2
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
