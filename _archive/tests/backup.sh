#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools nix jq rg

backup_state_paths="$(NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" nix eval --json --impure --expr "
  let
    flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
    vars = import ${TESTS_REPO_ROOT}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
  in
    vars.backupStatePaths
")"
backup_critical_paths="$(NIX_CONFIG="${NIX_CONFIG:-experimental-features = nix-command flakes}" nix eval --json --impure --expr "
  let
    flake = builtins.getFlake (toString ${TESTS_REPO_ROOT});
    vars = import ${TESTS_REPO_ROOT}/vars.nix { lib = flake.inputs.nixpkgs.lib; };
  in
    vars.backupCriticalDataPaths
")"
media_data_root="$(nix_eval_var 'vars.mediaDataRoot')"
workspace_data_root="$(nix_eval_var 'vars.workspaceDataRoot')"
mail_archive_ui_data_dir="$(nix_eval_var 'vars.mailArchiveUiDataDir')"
mail_archive_store_root="$(nix_eval_var 'vars.mailArchiveStoreRoot')"

echo "ℹ️ Checking backup vars and module wiring…"
require_fixed vars.nix 'enableBackups = true;' \
  "vars.nix must enable the backup scaffold."
require_fixed vars.nix 'enableBackupDisk = false;' \
  "vars.nix must leave the backup disk scaffold disabled until the hardware is connected."
require_fixed vars.nix 'backupDisk = null;' \
  "vars.nix must default backupDisk to null until a stable by-id entry is available."
require_fixed vars.nix 'backupMountPoint = "/mnt/backup";' \
  "vars.nix must define the backup mount point."
require_fixed vars.nix 'backupRepository = "${backupMountPoint}/restic/server-state";' \
  "vars.nix must define the restic repository path on the backup disk."
require_fixed vars.nix 'backupTimer = "*-*-* 20:30:00";' \
  "vars.nix must define the backup timer."
require_fixed vars.nix 'backupPruneTimer = "Sat *-*-* 21:00:00";' \
  "vars.nix must define the prune timer."
require_fixed configuration.nix './modules/backup' \
  "configuration.nix must explicitly import the backup module."
require_fixed modules/backup/default.nix 'services.restic.backups' \
  "The backup module must declare restic backups."
require_fixed modules/backup/default.nix 'backupCriticalDataPaths' \
  "The backup module must leave a dedicated extension point for later critical data paths."
require_fixed secrets/agenix.nix 'resticPassword = { file = ./resticPassword.age; owner = "root"; mode = "0400"; };' \
  "secrets/agenix.nix must declare the restic repository password."

echo "ℹ️ Checking first-pass backup scope…"
require_json_equal "$backup_critical_paths" '[]' \
  "vars.backupCriticalDataPaths must default to an empty list."
forbid_json_contains "$backup_state_paths" "$media_data_root" \
  "The initial backup scope must not include the media data root."
require_fixed vars.nix 'mailArchiveUiDataDir = "${appdataRoot}/mail-archive-ui";' \
  "Mail archive UI state must remain rooted under appdata so it stays inside the backup scope."
forbid_json_contains "$backup_state_paths" "$workspace_data_root" \
  "The initial backup scope must not include the workspace data root."
forbid_json_contains "$backup_state_paths" "$mail_archive_store_root" \
  "Downloaded mail archives must stay outside the backup state scope."
forbid_json_contains "$backup_critical_paths" "$media_data_root" \
  "Critical backup paths must not include the media data root by default."
forbid_json_contains "$backup_critical_paths" "$workspace_data_root" \
  "Critical backup paths must not include the workspace data root by default."
forbid_json_contains "$backup_critical_paths" "$mail_archive_store_root" \
  "Critical backup paths must not include downloaded mail archives by default."

echo "✅ Backup policy tests passed."
