#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq rg nix

echo "ℹ️ Checking active bootstrap and documentation files…"
for required_path in \
  README.md \
  flake.nix \
  flake.lock \
  configuration.nix \
  vars.nix \
  disko.nix \
  disko-system.nix \
  scripts/check-repo.sh \
  scripts/cold-storage.sh \
  scripts/deploy-validated.sh \
  scripts/encrypt-staged-secrets.sh \
  scripts/format-data-disks.sh \
  scripts/format-system-disk.sh \
  scripts/generate-managed-secrets.sh \
  scripts/gen-all-secrets.sh \
  scripts/lib-destructive-wrapper.sh \
  scripts/lib-repo.sh \
  scripts/lib-storage-health.sh \
  scripts/lib-secrets.sh \
  scripts/power-audit.sh \
  scripts/runtime-readiness.sh \
  documentation/quickstart.md \
  documentation/restore-and-recovery.md \
  documentation/operations.md \
  documentation/kanidm.md \
  rust/apps/mail-archive-ui/README.md \
  modules/Core_Modules/data-disks/default.nix \
  modules/Core_Modules/caddy/default.nix \
  modules/Core_Modules/kanidm/default.nix \
  modules/Core_Modules/kanidm/service.nix \
  modules/Core_Modules/kanidm/provision.nix \
  modules/Core_Modules/kanidm/branding.nix \
  modules/Core_Modules/kanidm/account-policy.nix \
  modules/Core_Modules/kanidm/user-tui.nix \
  modules/Core_Modules/storage/layout.nix \
  modules/Core_Modules/storage/migrations.nix \
  modules/audiobookshelf/service.nix \
  modules/audiobookshelf/storage-migration.nix \
  modules/audiobookshelf/oidc-bootstrap.nix \
  modules/audiobookshelf/root-bootstrap.nix \
  modules/paperless/package.nix \
  modules/paperless/service.nix \
  modules/paperless/bootstrap.nix \
  modules/jellyfin/service.nix \
  modules/jellyfin/network-config.nix \
  secrets/agenix.nix
do
  if [[ ! -e "$required_path" ]]; then
    echo "❌ Required active file is missing: $required_path"
    exit 1
  fi
done

if [[ -e disko-install.nix ]]; then
  echo "❌ disko-install.nix must not exist; the combined destructive Disko path was removed."
  exit 1
fi

expected_doc_files="$(
  printf '%s\n' \
    documentation/kanidm.md \
    documentation/operations.md \
    documentation/quickstart.md \
    documentation/restore-and-recovery.md
)"
actual_doc_files="$(find documentation -maxdepth 1 -type f -name '*.md' | sort)"
require_json_equal "$(printf '%s\n' "$actual_doc_files" | jq -R -s 'split("\n")[:-1]')" \
  "$(printf '%s\n' "$expected_doc_files" | jq -R -s 'split("\n")[:-1]')" \
  "Documentation root must contain only the canonical operator docs."

if find documentation/references -maxdepth 1 -type f -name '*.md' | grep -q .; then
  echo "❌ Reference documentation files must be removed."
  exit 1
fi

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
require_fixed documentation/quickstart.md 'scripts/gen-all-secrets.sh' \
  "Quickstart must document the single public secrets entrypoint."
require_fixed documentation/quickstart.md 'storageAlertWebhookUrl' \
  "Quickstart must document the staged storage alert webhook secret."
require_fixed documentation/quickstart.md 'CURRENT_SERVER_IP' \
  "Quickstart must document the current reachable SSH override used to install the agenix key."
require_fixed documentation/quickstart.md './scripts/format-system-disk.sh' \
  "Quickstart must document the safer system-disk wrapper."
require_fixed documentation/quickstart.md './scripts/format-data-disks.sh' \
  "Quickstart must document the safer data-disk wrapper."
forbid_match documentation/quickstart.md 'nix flake check --no-build|scripts/check-repo.sh|tests/run-all.sh|TARGET_SERVER_IP' \
  "Quickstart must defer the validation gate and guarded deploy commands to Operations."
require_fixed documentation/operations.md 'nix flake check --no-build' \
  "Operations must own the flake validation command."
require_fixed documentation/operations.md 'scripts/check-repo.sh' \
  "Operations must own the repo validation helper."
require_fixed documentation/operations.md 'tests/run-all.sh' \
  "Operations must explain that the repo helper runs the full test suite."
require_fixed documentation/operations.md 'scripts/deploy-validated.sh' \
  "Operations must document the guarded deploy helper."
require_fixed documentation/operations.md 'TARGET_SERVER_IP' \
  "Operations must document the intended reserved LAN IP variable."
require_fixed documentation/operations.md 'CURRENT_SERVER_IP' \
  "Operations must document the current reachable IP override."
require_fixed documentation/operations.md './scripts/runtime-readiness.sh' \
  "Operations must document the runtime validation helper."
require_fixed documentation/operations.md './scripts/power-audit.sh' \
  "Operations must document the power audit helper."
forbid_match documentation/operations.md './scripts/format-system-disk.sh|./scripts/format-data-disks.sh|./scripts/cold-storage.sh mount|./scripts/cold-storage.sh unmount' \
  "Operations must link out instead of duplicating destructive or recovery command ownership."
require_fixed documentation/kanidm.md 'kanidm-user-tui' \
  "Kanidm guide must document the admin TUI."
require_fixed documentation/kanidm.md 'kanidm login' \
  "Kanidm guide must own the delegated login flow."
require_fixed documentation/kanidm.md 'kanidm reauth' \
  "Kanidm guide must own the reauthentication flow."
require_fixed documentation/kanidm.md 'kanidm group add-members' \
  "Kanidm guide must own group membership commands."
forbid_match documentation/kanidm.md 'runtime-readiness\.sh|nix flake check --no-build|scripts/check-repo.sh' \
  "Kanidm guide must not duplicate generic validation workflows."
require_fixed rust/apps/mail-archive-ui/README.md 'mail-archive-users' \
  "Mail archive UI README must document the access group."
require_fixed AGENTS.md 'TARGET_SERVER_IP' \
  "AGENTS.md must document the intended reserved LAN IP variable."
require_fixed AGENTS.md 'CURRENT_SERVER_IP' \
  "AGENTS.md must document the current reachable IP override."
require_fixed scripts/check-repo.sh 'tests/run-all.sh' \
  "Repository validation must use the slim test entrypoint."
require_fixed documentation/restore-and-recovery.md './scripts/format-data-disks.sh' \
  "Restore-and-recovery must use the safer data-disk wrapper."
require_fixed documentation/restore-and-recovery.md './scripts/cold-storage.sh mount' \
  "Restore-and-recovery must own the cold-storage mount workflow."
require_fixed documentation/restore-and-recovery.md './scripts/cold-storage.sh unmount' \
  "Restore-and-recovery must own the cold-storage unmount workflow."
require_fixed documentation/restore-and-recovery.md 'not the supported operator workflow' \
  "Restore-and-recovery must warn that direct Disko commands are not the supported operator workflow."
forbid_match documentation/restore-and-recovery.md 'nix flake check --no-build|scripts/check-repo.sh|scripts/deploy-validated.sh' \
  "Restore-and-recovery must not duplicate the validation gate or guarded deploy commands."
require_fixed scripts/deploy-validated.sh 'nix flake check --no-build' \
  "Deploy wrapper must run flake checks first."
require_fixed scripts/runtime-readiness.sh '== ZFS ==' \
  "Runtime readiness must include the ZFS pool section."
require_fixed scripts/runtime-readiness.sh '== SMART ==' \
  "Runtime readiness must include the SMART degradation section."
require_fixed scripts/lib-storage-health.sh '--mode warn|strict' \
  "The shared SMART helper must expose warn and strict modes."
require_fixed scripts/deploy-validated.sh 'source "$script_dir/lib-repo.sh"' \
  "Deploy wrapper must source the shared repo helper."
require_fixed scripts/runtime-readiness.sh 'source "$script_dir/lib-repo.sh"' \
  "Runtime readiness must source the shared repo helper."
require_fixed scripts/format-system-disk.sh 'source "$script_dir/lib-destructive-wrapper.sh"' \
  "System-disk wrapper must source the shared destructive helper."
require_fixed scripts/format-data-disks.sh 'source "$script_dir/lib-destructive-wrapper.sh"' \
  "Data-disk wrapper must source the shared destructive helper."

echo "✅ Bootstrap readiness tests passed."
