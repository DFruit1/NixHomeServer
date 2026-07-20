#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash cut head rg

require_fixed bootstrap/apply-disko.sh \
  'Cannot prove preserved-pool disk identity because this configured member is absent' \
  "System-only recovery must fail when any configured preserved member cannot be resolved."
require_fixed bootstrap/apply-disko.sh \
  'aliases preserved data-pool member' \
  "System-only recovery must reject aliases between selected and preserved disks."
require_fixed bootstrap/apply-disko.sh \
  'preserved_canonical_by_id[$disk_id]' \
  "System-only recovery must retain canonical preserved-disk identities for its final recheck."
require_fixed bootstrap/apply-disko.sh \
  'preserved_identity_by_id[$disk_id]' \
  "System-only recovery must retain preserved-disk hardware fingerprints for its final recheck."

require_fixed scripts/admin/validate-config-readiness.sh \
  'git status --porcelain=v1 --untracked-files=all' \
  "Target-hardware readiness must inventory every kind of worktree change."
require_fixed scripts/admin/validate-config-readiness.sh \
  'repository worktree is not clean' \
  "Target-hardware readiness must block an uncommitted destructive bootstrap source."

require_fixed bootstrap/apply-disko.sh \
  'active_secret_names_json="$(nix_json_for_host "$host" "builtins.attrNames cfg.age.secrets")"' \
  "Destructive bootstrap must derive active ciphertexts from its pinned host."
require_fixed bootstrap/apply-disko.sh \
  'bash "$pinned_source_path/scripts/helpers/verify-bootstrap-secrets.sh"' \
  "Destructive bootstrap must decrypt and validate pinned active ciphertexts before wiping."

secret_check_line="$(
  rg -n -F 'bash "$pinned_source_path/scripts/helpers/verify-bootstrap-secrets.sh"' \
    bootstrap/apply-disko.sh | head -n 1 | cut -d: -f1
)"
target_build_line="$(
  rg -n -F 'target_system="$(build_pinned_target_system "$host")"' \
    bootstrap/apply-disko.sh | head -n 1 | cut -d: -f1
)"
final_network_line="$(
  rg -n -F 'verify_installer_network "post-build final validation"' \
    bootstrap/apply-disko.sh | head -n 1 | cut -d: -f1
)"
final_disk_line="$(
  rg -n -F 'Confirmed disk disappeared while building the Disko plan' \
    bootstrap/apply-disko.sh | head -n 1 | cut -d: -f1
)"
final_age_line="$(
  rg -n -F 'verify_age_recovery_copies "post-build recheck"' \
    bootstrap/apply-disko.sh | head -n 1 | cut -d: -f1
)"
exec_line="$(
  rg -n -F 'exec "$disko_script"' bootstrap/apply-disko.sh \
    | head -n 1 | cut -d: -f1
)"
if [[ -z "$secret_check_line" || -z "$target_build_line" \
  || -z "$final_network_line" || -z "$final_disk_line" \
  || -z "$final_age_line" || -z "$exec_line" ]] \
  || ((secret_check_line >= target_build_line \
    || target_build_line >= final_network_line \
    || final_network_line >= final_disk_line \
    || final_disk_line >= final_age_line \
    || final_age_line >= exec_line)); then
  echo "❌ Pinned secrets, builds, and final network/disk/key checks are ordered unsafely."
  exit 1
fi

require_fixed documentation/restore-and-recovery.md \
  'server_settings="$(' \
  "Recovery guidance must evaluate one exact host before deriving storage commands."
require_fixed documentation/restore-and-recovery.md \
  'pool_name="$(jq -er' \
  "Recovery guidance must use the evaluated pool name."
require_fixed documentation/restore-and-recovery.md \
  'data_root="$(jq -er' \
  "Recovery guidance must use the evaluated data root."
require_fixed documentation/restore-and-recovery.md \
  'backup_root="$(jq -er' \
  "Recovery guidance must use the evaluated backup root."
require_fixed documentation/restore-and-recovery.md \
  'git config --local user.name "$(jq -er' \
  "System-SSD recovery must configure local Git identity before its recovery commit."
require_fixed documentation/restore-and-recovery.md \
  'git diff --cached --check' \
  "System-SSD recovery must validate the staged replacement-disk commit."
require_fixed documentation/restore-and-recovery.md \
  'test -z "$(git status --short)"' \
  "System-SSD recovery must prove the checkout is clean around its recovery commit."
forbid_match documentation/restore-and-recovery.md \
  'zpool (status|replace|scrub).* data([[:space:]]|$)' \
  "Recovery commands must not hard-code the default ZFS pool name."

echo "✅ Destructive bootstrap and system-recovery guard regressions passed."
