#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq rg

echo "ℹ️ Checking canonical documentation set…"
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

echo "ℹ️ Checking active docs for retired references…"
forbid_match README.md 'superceded/|_archive/' \
  "README must not point operators at retired archive paths."
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

echo "ℹ️ Checking entrypoint ownership in docs…"
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
require_fixed documentation/operations.md 'scripts/check-repo.sh --full' \
  "Operations must document the exhaustive repo validation mode."
require_fixed documentation/operations.md 'scripts/check-docs.sh' \
  "Operations must document the manual docs and repo-audit entrypoint."
require_fixed documentation/operations.md 'scripts/deploy-validated.sh' \
  "Operations must document the guarded deploy helper."
require_fixed documentation/operations.md 'TARGET_SERVER_IP' \
  "Operations must document the intended reserved LAN IP variable."
require_fixed documentation/operations.md 'CURRENT_SERVER_IP' \
  "Operations must document the current reachable IP override."
require_fixed documentation/operations.md './scripts/runtime-readiness.sh' \
  "Operations must document the runtime validation helper."
require_fixed documentation/operations.md '--profile deploy' \
  "Operations must document the explicit deploy runtime-health profile."
require_fixed documentation/operations.md 'runtime-health-report.timer' \
  "Operations must document the runtime health monitoring timer."
require_fixed documentation/operations.md './scripts/power-audit.sh' \
  "Operations must document the power audit helper."
forbid_match documentation/operations.md '--require-online-zpool' \
  "Operations must prefer the explicit deploy runtime-health profile over the compatibility alias."
forbid_match documentation/operations.md './scripts/format-system-disk.sh|./scripts/format-data-disks.sh|./scripts/cold-storage.sh mount|./scripts/cold-storage.sh unmount' \
  "Operations must link out instead of duplicating destructive or recovery command ownership."
require_fixed documentation/kanidm.md 'kanidm-admin' \
  "Kanidm guide must document the Rust operator CLI."
require_fixed documentation/kanidm.md 'kanidm-admin interactive' \
  "Kanidm guide must document the interactive kanidm-admin workflow."
require_fixed documentation/kanidm.md 'kanidm login' \
  "Kanidm guide must own the delegated login flow."
require_fixed documentation/kanidm.md 'kanidm reauth' \
  "Kanidm guide must own the reauthentication flow."
require_fixed documentation/kanidm.md 'kanidm-admin users reset-token' \
  "Kanidm guide must document Kanidm password reset token creation via the Rust CLI."
require_fixed documentation/kanidm.md 'kanidm group add-members' \
  "Kanidm guide must own group membership commands."
forbid_match documentation/kanidm.md 'kanidm-user-tui' \
  "Kanidm guide must not retain the retired TUI workflow."
forbid_match documentation/kanidm.md 'jellyfin-users|jellyfin-admin|why-denied --app jellyfin' \
  "Kanidm guide must not document Jellyfin as a Kanidm-managed app."
forbid_match documentation/kanidm.md 'runtime-readiness\.sh|nix flake check --no-build|scripts/check-repo.sh' \
  "Kanidm guide must not duplicate generic validation workflows."
require_fixed documentation/restore-and-recovery.md './scripts/format-data-disks.sh' \
  "Restore-and-recovery must use the safer data-disk wrapper."
require_fixed documentation/restore-and-recovery.md 'restic-backups-system-state.service' \
  "Restore-and-recovery must require a fresh SSD-backed system-state snapshot before destructive recovery."
require_fixed documentation/restore-and-recovery.md 'app-state-roots.tsv' \
  "Restore-and-recovery must document the app-state inventory used for SSD-backed restores."
require_fixed documentation/restore-and-recovery.md '/var/lib/jellyfin' \
  "Restore-and-recovery must explicitly call out Jellyfin's SSD-backed local state."
require_fixed documentation/restore-and-recovery.md './scripts/cold-storage.sh mount' \
  "Restore-and-recovery must own the cold-storage mount workflow."
require_fixed documentation/restore-and-recovery.md './scripts/cold-storage.sh unmount' \
  "Restore-and-recovery must own the cold-storage unmount workflow."
require_fixed documentation/restore-and-recovery.md 'not the supported operator workflow' \
  "Restore-and-recovery must warn that direct Disko commands are not the supported operator workflow."
forbid_match documentation/restore-and-recovery.md 'nix flake check --no-build|scripts/check-repo.sh|scripts/deploy-validated.sh' \
  "Restore-and-recovery must not duplicate the validation gate or guarded deploy commands."
require_fixed AGENTS.md 'TARGET_SERVER_IP' \
  "AGENTS.md must document the intended reserved LAN IP variable."
require_fixed AGENTS.md 'CURRENT_SERVER_IP' \
  "AGENTS.md must document the current reachable IP override."
require_fixed rust/apps/mail-archive-ui/README.md 'mail-archive-users' \
  "Mail archive UI README must document the access group."

echo "✅ Manual documentation checks passed."
