#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/../helpers/repo-common.sh"
init_repo_root
cd_repo_root
ensure_default_nix_config

need nix

# Run the conservative capacity-triggered disk cleanup against the workstation
# main SSD. This is the same helper that deploy.sh runs before staging; it can
# be scheduled independently (for example as a root systemd timer) so the store
# is collected between deploys too. Journal and tmpfile actions require root;
# running as an unprivileged user still collects the Nix store and reports the
# remaining action failures to the journal.

trigger_percent="$(nix_flake_var 'toString vars.localDiskCleanup.triggerPercent')"
monitor_paths="$(nix_flake_var 'builtins.concatStringsSep " " vars.localDiskCleanup.monitorPaths')"
journal_vacuum_time="$(nix_flake_var 'vars.localDiskCleanup.journalVacuumTime')"
retention_days="$(nix_flake_var 'toString vars.nixGcRetentionDays')"

runtime_dir="${XDG_RUNTIME_DIR:-/tmp}/nixhomeserver-${UID}"
install -d -m 0755 -- "$runtime_dir"

DISK_CLEANUP_TRIGGER_PERCENT="$trigger_percent" \
  DISK_CLEANUP_MONITOR_PATHS="$monitor_paths" \
  DISK_CLEANUP_JOURNAL_VACUUM_TIME="$journal_vacuum_time" \
  DISK_CLEANUP_NIX_GC_RETENTION_DAYS="$retention_days" \
  DISK_CLEANUP_LOCK_PATH="$runtime_dir/maintenance.lock" \
  DISK_CLEANUP_FAILURE_MARKER="$runtime_dir/disk-cleanup-failed" \
  bash "$script_dir/../helpers/disk-space-cleanup.sh"