#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools rg nix

echo "ℹ️ Checking active bootstrap and documentation files…"
for required_path in \
  README.md \
  flake.nix \
  flake.lock \
  configuration.nix \
  vars.nix \
  disko.nix \
  disko-install.nix \
  disko-system.nix \
  scripts/check-repo.sh \
  scripts/cold-storage.sh \
  scripts/deploy-validated.sh \
  scripts/encrypt-staged-secrets.sh \
  scripts/generate-managed-secrets.sh \
  scripts/gen-all-secrets.sh \
  scripts/lib-storage-health.sh \
  scripts/lib-secrets.sh \
  scripts/power-audit.sh \
  scripts/runtime-readiness.sh \
  documentation/README.md \
  documentation/first-admin-session.md \
  documentation/quickstart.md \
  documentation/install-from-scratch.md \
  documentation/restore-and-recovery.md \
  documentation/secrets-and-prereqs.md \
  documentation/networking-and-access.md \
  documentation/operations.md \
  documentation/power-management.md \
  documentation/kanidm.md \
  documentation/mail-archive.md \
  documentation/storage-monitoring.md \
  documentation/runtime-validation.md \
  modules/Core_Modules/data-disks/default.nix \
  modules/Core_Modules/caddy/default.nix \
  modules/Core_Modules/kanidm/default.nix \
  secrets/agenix.nix
do
  if [[ ! -e "$required_path" ]]; then
    echo "❌ Required active file is missing: $required_path"
    exit 1
  fi
done

echo "ℹ️ Checking vars.nix stays focused on host-editable values…"
require_fixed vars.nix 'hostname = "server";' \
  "vars.nix must keep the canonical hostname."
require_fixed vars.nix 'serverLanIP = "192.168.8.12";' \
  "vars.nix must keep the reserved LAN IP declaration."
forbid_match vars.nix 'enableDietPiCompanion|piLanIP|legacyPhotosDomain|legacyAudiobooksDomain|legacyKavitaDomain|legacyJellyfinDomain|powerManagement = \{|rustScaffold' \
  "vars.nix must not retain archived DietPi, legacy-host, power-management, or rust-scaffold settings."
forbid_match vars.nix 'cloudflareTunnelID|cloudflareAccountID' \
  "vars.nix must not retain unused Cloudflare account or tunnel ID values."
forbid_match vars.nix 'defaultGateway' \
  "vars.nix must not retain defaultGateway."

echo "ℹ️ Checking active docs and scripts for archived features…"
forbid_match README.md 'superceded/' \
  "README must not point to the retired superceded path."
forbid_match README.md '_archive/' \
  "README must not point operators at a removed archive path."
forbid_match documentation/README.md '_archive/' \
  "Documentation index must not point to a removed archive path."
forbid_match documentation 'DietPi|dietpi|piLanIP|enableDietPiCompanion' \
  "Active documentation must not mention the abandoned DietPi path."
forbid_match documentation 'photo\.<domain>|audiobook\.<domain>|book\.<domain>|video\.<domain>' \
  "Active documentation must not mention legacy redirect hostnames."
forbid_match documentation 'rust-scaffold|services\.rust-scaffold' \
  "Active documentation must not describe the archived rust-scaffold path."
forbid_match documentation 'defaultGateway' \
  "Active documentation must not tell operators to manage defaultGateway in vars.nix."
forbid_match AGENTS.md '192\.168\.0\.144' \
  "AGENTS.md must not retain the old hardcoded LAN IP."
forbid_match documentation '192\.168\.0\.144' \
  "Active documentation must not retain the old hardcoded LAN IP."

echo "ℹ️ Checking deploy and validation entrypoints…"
require_fixed documentation/quickstart.md 'nix flake check --no-build' \
  "Quickstart must document flake checks."
require_fixed documentation/quickstart.md 'scripts/check-repo.sh' \
  "Quickstart must document the repo validation helper."
require_fixed documentation/quickstart.md 'tests/run-all.sh' \
  "Quickstart must document the slim test entrypoint."
require_fixed documentation/quickstart.md 'scripts/gen-all-secrets.sh' \
  "Quickstart must document the single public secrets entrypoint."
require_fixed documentation/quickstart.md 'storageAlertWebhookUrl' \
  "Quickstart must document the staged storage alert webhook secret."
require_fixed documentation/quickstart.md 'TARGET_SERVER_IP' \
  "Quickstart must document the intended reserved LAN IP variable."
require_fixed documentation/quickstart.md 'CURRENT_SERVER_IP' \
  "Quickstart must document the current reachable IP override."
require_fixed documentation/README.md 'storage-monitoring.md' \
  "Documentation index must expose the storage monitoring runbook."
require_fixed documentation/secrets-and-prereqs.md 'storageAlertWebhookUrl' \
  "Secrets guide must document the staged storage alert webhook secret."
require_fixed documentation/operations.md 'tests/core-config.sh' \
  "Operations must mention the compact core-config validation."
require_fixed documentation/operations.md 'scripts/deploy-validated.sh' \
  "Operations must document the guarded deploy helper."
require_fixed documentation/operations.md 'TARGET_SERVER_IP' \
  "Operations must document the intended reserved LAN IP variable."
require_fixed documentation/operations.md 'CURRENT_SERVER_IP' \
  "Operations must document the current reachable IP override."
require_fixed AGENTS.md 'TARGET_SERVER_IP' \
  "AGENTS.md must document the intended reserved LAN IP variable."
require_fixed AGENTS.md 'CURRENT_SERVER_IP' \
  "AGENTS.md must document the current reachable IP override."
require_fixed scripts/check-repo.sh 'tests/run-all.sh' \
  "Repository validation must use the slim test entrypoint."
require_fixed scripts/deploy-validated.sh 'nix flake check --no-build' \
  "Deploy wrapper must run flake checks first."
require_fixed scripts/runtime-readiness.sh '== ZFS ==' \
  "Runtime readiness must include the ZFS pool section."
require_fixed scripts/runtime-readiness.sh '== SMART ==' \
  "Runtime readiness must include the SMART degradation section."
require_fixed scripts/lib-storage-health.sh '--mode warn|strict' \
  "The shared SMART helper must expose warn and strict modes."

echo "✅ Bootstrap readiness tests passed."
