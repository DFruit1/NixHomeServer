#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
source "$script_dir/helpers/runtime-health-common.sh"
init_repo_root "RESTORE_VERIFY_REPO_ROOT"
cd_repo_root
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/verify-system-state-restore.sh [--format text|json] [--target-dir <dir>] [--read-data-subset <subset>]

Verify that the latest system-state restic backup can be inspected and partially
restored. This is read-only with respect to the backup repository and restores
only into a temporary directory.
EOF
}

output_format="text"
target_dir=""
read_data_subset="${RESTORE_VERIFY_READ_DATA_SUBSET:-1/20}"

while (($# > 0)); do
  case "$1" in
    --format)
      output_format="${2:-}"
      shift 2
      ;;
    --target-dir)
      target_dir="${2:-}"
      shift 2
      ;;
    --read-data-subset)
      read_data_subset="${2:-}"
      shift 2
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

case "$output_format" in
  text|json) ;;
  *)
    echo "error: --format must be text or json" >&2
    exit 1
    ;;
esac

need jq nix restic sqlite3

runtime_health_load_snapshot

repository="$(runtime_health_snapshot_query '.backup.repositoryPath' | jq -r '.')"
mount_point="$(runtime_health_snapshot_query '.backup.mountPoint' | jq -r '.')"
metadata_root="$(runtime_health_snapshot_query '.backup.metadataRoot' | jq -r '.')"
timestamp_file="$(runtime_health_snapshot_query '.backup.timestampFile' | jq -r '.')"
app_state_file="$(runtime_health_snapshot_query '.backup.appStateFile' | jq -r '.')"
critical_paths_file="$(runtime_health_snapshot_query '.backup.criticalPathsFile' | jq -r '.')"
postgresql_dump_file="$(runtime_health_snapshot_query '.backup.postgresqlDumpFile' | jq -r '.')"
password_file="$(nix_json 'cfg.services.restic.backups.system-state.passwordFile' | jq -r '.')"
postgres_enabled="$(nix_json 'cfg.services.postgresql.enable' | jq -r '.')"
mail_archive_enabled="$(nix_json 'cfg.services.mail-archive-ui.enable or false' | jq -r '.')"

created_target=false
if [[ -z "$target_dir" ]]; then
  target_dir="$(mktemp -d /var/tmp/system-state-restore-verify.XXXXXX)"
  created_target=true
fi
if [[ "$created_target" == true ]]; then
  trap 'rm -rf "$target_dir"' EXIT
fi

results_file="$(mktemp)"
trap 'rm -f "$results_file"; if [[ "$created_target" == true ]]; then rm -rf "$target_dir"; fi' EXIT
: >"$results_file"

append_result() {
  local name="$1" severity="$2" detail="$3"
  jq -nc --arg name "$name" --arg severity "$severity" --arg detail "$detail" \
    '{name: $name, severity: $severity, detail: $detail}' >>"$results_file"
}

emit_text() {
  if [[ "$output_format" == "text" ]]; then
    printf '%s\n' "$*"
  fi
}

if [[ ! -d "$mount_point" || ! -d "$repository" ]]; then
  if [[ -x "$repo_root/result/bin/manage-backup-target" ]]; then
    "$repo_root/result/bin/manage-backup-target" mount || true
  elif [[ -x "$repo_root/scripts/manage-backup-target.sh" ]]; then
    bash "$repo_root/scripts/manage-backup-target.sh" mount || true
  fi
fi

if [[ ! -d "$repository" ]]; then
  append_result repository CRITICAL "repository path missing: $repository"
elif [[ ! -r "$password_file" ]]; then
  append_result password CRITICAL "restic password file is not readable: $password_file"
else
  if restic -r "$repository" --password-file "$password_file" snapshots --json --tag system-state >/dev/null; then
    append_result snapshots OK "system-state snapshots are listable"
  else
    append_result snapshots CRITICAL "restic snapshots failed"
  fi

  if restic -r "$repository" --password-file "$password_file" check --read-data-subset "$read_data_subset"; then
    append_result check OK "restic check passed with read-data-subset=$read_data_subset"
  else
    append_result check CRITICAL "restic check failed with read-data-subset=$read_data_subset"
  fi

  restore_args=(
    restore latest
    --target "$target_dir"
    --tag system-state
    --include "$timestamp_file"
    --include "$app_state_file"
    --include "$critical_paths_file"
    --include "$metadata_root/mail-archive-attachments.json"
    --include "$(dirname "$postgresql_dump_file")"
  )
  if restic -r "$repository" --password-file "$password_file" "${restore_args[@]}"; then
    append_result restore OK "latest metadata and dump artifacts restored into temporary directory"
  else
    append_result restore CRITICAL "restic restore of metadata and dumps failed"
  fi
fi

restored_path() {
  local absolute_path="$1"
  printf '%s/%s\n' "$target_dir" "${absolute_path#/}"
}

for spec in \
  "timestamp:$(restored_path "$timestamp_file")" \
  "app-state:$(restored_path "$app_state_file")" \
  "critical-paths:$(restored_path "$critical_paths_file")"
do
  IFS=: read -r label path <<<"$spec"
  if [[ -s "$path" ]]; then
    append_result "$label" OK "restored artifact present"
  else
    append_result "$label" CRITICAL "restored artifact missing: $path"
  fi
done

while IFS= read -r sqlite_db; do
  [[ -n "$sqlite_db" ]] || continue
  if sqlite3 "$sqlite_db" 'pragma quick_check;' | grep -qx ok; then
    append_result "sqlite:$(basename "$sqlite_db")" OK "sqlite quick_check passed"
  else
    append_result "sqlite:$(basename "$sqlite_db")" CRITICAL "sqlite quick_check failed"
  fi
done < <(find "$(restored_path /persist/appdata/system-state-backup/dumps)" -type f -name '*.sqlite3' 2>/dev/null || true)

restored_pg_dump="$(restored_path "$postgresql_dump_file")"
if [[ "$postgres_enabled" == "true" ]]; then
  if [[ -s "$restored_pg_dump" ]] && grep -Eq '^(--|CREATE|SET )' "$restored_pg_dump"; then
    append_result postgresql-dump OK "postgresql logical dump restored"
  else
    append_result postgresql-dump CRITICAL "postgresql logical dump missing or implausible"
  fi
fi

if [[ "$mail_archive_enabled" == "true" ]]; then
  mail_report="$(restored_path "$metadata_root/mail-archive-attachments.json")"
  if [[ -s "$mail_report" ]] && jq -e type "$mail_report" >/dev/null; then
    append_result mail-archive-attachments OK "mail archive attachment verification report restored"
  else
    append_result mail-archive-attachments CRITICAL "mail archive attachment verification report missing or invalid"
  fi
fi

overall_severity="$(
  jq -sr '
    if any(.severity == "CRITICAL") then "CRITICAL"
    elif any(.severity == "WARN") then "WARN"
    else "OK"
    end
  ' "$results_file"
)"

if [[ "$output_format" == "json" ]]; then
  jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg repository "$repository" \
    --arg targetDir "$target_dir" \
    --arg overallSeverity "$overall_severity" \
    --arg readDataSubset "$read_data_subset" \
    --slurpfile results "$results_file" \
    '{
      timestamp: $timestamp,
      repository: $repository,
      targetDir: $targetDir,
      readDataSubset: $readDataSubset,
      overallSeverity: $overallSeverity,
      results: $results
    }'
else
  emit_text "System-state restore verification: $overall_severity"
  jq -r '. | "- \(.name): \(.severity) (\(.detail))"' "$results_file"
fi

if [[ "$overall_severity" == "CRITICAL" ]]; then
  exit 1
fi
