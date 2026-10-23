#!/usr/bin/env bash
# Collect cached backup health for the Homepage admin dashboard.
#
# This helper only reports measurements (timestamps, ages, sizes, counts). It
# deliberately makes no severity decision: the `/admin-dashboard` route maps
# ages to ok/warn/critical so the thresholds stay in one tested place. It never
# reads credentials and never prints file contents it was not asked for.
#
# Every source degrades independently: a missing or corrupt marker yields an
# `{error: ...}` section instead of failing the whole report, because a stale
# dashboard would be worse than an incomplete one.

set -euo pipefail

: "${JQ_BIN:=jq}"
: "${DATE_BIN:=date}"
: "${READLINK_BIN:=readlink}"
: "${MKTEMP_BIN:=mktemp}"
: "${MV_BIN:=mv}"
: "${CHMOD_BIN:=chmod}"
: "${CHGRP_BIN:=chgrp}"
: "${RM_BIN:=rm}"
: "${BASENAME_BIN:=basename}"
: "${DIRNAME_BIN:=dirname}"
: "${ZFS_BIN:=zfs}"
: "${ZPOOL_BIN:=zpool}"

usage() {
  cat <<'USAGE'
Usage: homepage-admin-dashboard-status.sh --output PATH [options]

  --output PATH                        cached status JSON to write
  --group NAME                         group allowed to read the cached status
  --now EPOCH                          override the collection clock (testing)
  --kopia-snapshot-marker PATH         last successful Kopia snapshot marker
  --kopia-snapshot-max-age-seconds N   freshness limit for the marker
  --kopia-verify-marker PATH           last successful deep-verification marker
  --kopia-verify-max-age-seconds N     freshness limit for the marker
  --logical-current-link PATH          symlink to the current logical generation
  --logical-max-age-seconds N          freshness limit for the generation
  --offsite-status-file PATH           MEGA mirror status event file
  --offsite-max-age-seconds N          freshness limit for the mirror
  --zfs-pool NAME                      ZFS pool to inspect for snapshot health
  --zfs-max-age-seconds N              freshness limit for automatic snapshots
USAGE
}

output=""
output_group=""
now=""
kopia_snapshot_marker=""
kopia_snapshot_max_age=""
kopia_verify_marker=""
kopia_verify_max_age=""
logical_current_link=""
logical_max_age=""
offsite_status_file=""
offsite_max_age=""
zfs_pool=""
zfs_max_age=""

while (($# > 0)); do
  case "$1" in
    --output) output="${2:?--output requires a value}"; shift 2 ;;
    --group) output_group="${2:?--group requires a value}"; shift 2 ;;
    --now) now="${2:?--now requires a value}"; shift 2 ;;
    --kopia-snapshot-marker) kopia_snapshot_marker="${2:?--kopia-snapshot-marker requires a value}"; shift 2 ;;
    --kopia-snapshot-max-age-seconds) kopia_snapshot_max_age="${2:?--kopia-snapshot-max-age-seconds requires a value}"; shift 2 ;;
    --kopia-verify-marker) kopia_verify_marker="${2:?--kopia-verify-marker requires a value}"; shift 2 ;;
    --kopia-verify-max-age-seconds) kopia_verify_max_age="${2:?--kopia-verify-max-age-seconds requires a value}"; shift 2 ;;
    --logical-current-link) logical_current_link="${2:?--logical-current-link requires a value}"; shift 2 ;;
    --logical-max-age-seconds) logical_max_age="${2:?--logical-max-age-seconds requires a value}"; shift 2 ;;
    --offsite-status-file) offsite_status_file="${2:?--offsite-status-file requires a value}"; shift 2 ;;
    --offsite-max-age-seconds) offsite_max_age="${2:?--offsite-max-age-seconds requires a value}"; shift 2 ;;
    --zfs-pool) zfs_pool="${2:?--zfs-pool requires a value}"; shift 2 ;;
    --zfs-max-age-seconds) zfs_max_age="${2:?--zfs-max-age-seconds requires a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 64 ;;
  esac
done

[[ -n "$output" ]] || { echo "Missing --output" >&2; exit 64; }
if [[ -z "$now" ]]; then
  now="$($DATE_BIN +%s)"
fi
[[ "$now" =~ ^[0-9]+$ ]] || { echo "--now must be an epoch second count" >&2; exit 64; }

require_positive() {
  local name="$1" value="$2"
  [[ -z "$value" ]] || [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
    echo "$name must be a positive integer" >&2
    exit 64
  }
}

require_positive --kopia-snapshot-max-age-seconds "$kopia_snapshot_max_age"
require_positive --kopia-verify-max-age-seconds "$kopia_verify_max_age"
require_positive --logical-max-age-seconds "$logical_max_age"
require_positive --offsite-max-age-seconds "$offsite_max_age"
require_positive --zfs-max-age-seconds "$zfs_max_age"

timestamp_pattern='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$'

fail_section() {
  local code="$1" detail="${2:-}"
  $JQ_BIN -nc --arg error "$code" --arg detail "$detail" \
    'if $detail == "" then {error:$error} else {error:$error,detail:$detail} end'
}

# Report one timestamp measurement without judging its freshness.
measure() {
  local completed_at="$1" max_age="$2" completed_epoch age
  [[ "$completed_at" =~ $timestamp_pattern ]] || return 1
  completed_epoch="$($DATE_BIN --date "$completed_at" +%s 2>/dev/null)" || return 1
  [[ "$completed_epoch" =~ ^[0-9]+$ ]] || return 1
  age=$((now - completed_epoch))
  (( age >= 0 )) || return 1
  $JQ_BIN -nc \
    --arg completedAt "$completed_at" \
    --argjson ageSeconds "$age" \
    --argjson maxAgeSeconds "$max_age" \
    '{completedAt:$completedAt,ageSeconds:$ageSeconds,maxAgeSeconds:$maxAgeSeconds}'
}

marker_section() {
  local path="$1" max_age="$2" completed_at
  if [[ -z "$path" ]]; then
    fail_section disabled
    return 0
  fi
  if [[ ! -s "$path" ]]; then
    fail_section missing "no freshness marker has been written yet"
    return 0
  fi
  if ! completed_at="$($JQ_BIN -er '.completedAt | select(type == "string" and length > 0)' "$path" 2>/dev/null)"; then
    fail_section invalid "freshness marker has no completedAt"
    return 0
  fi
  measure "$completed_at" "$max_age" || fail_section invalid "freshness marker has an unusable completedAt"
}

logical_section() {
  local link="$1" max_age="$2" target generation manifest completed_at base dumps_file extra
  if [[ -z "$link" ]]; then
    fail_section disabled
    return 0
  fi
  if [[ ! -e "$link" && ! -L "$link" ]]; then
    fail_section missing "no published logical backup generation"
    return 0
  fi
  target="$($READLINK_BIN -f -- "$link" 2>/dev/null || true)"
  if [[ -z "$target" || ! -d "$target" ]]; then
    fail_section invalid "the current generation link does not resolve to a directory"
    return 0
  fi
  generation="$($BASENAME_BIN "$target")"
  manifest="$target/metadata/manifest.json"
  if ! completed_at="$($JQ_BIN -er '.createdAt | select(type == "string" and length > 0)' "$manifest" 2>/dev/null)"; then
    fail_section invalid "logical backup manifest has no createdAt"
    return 0
  fi
  if ! base="$(measure "$completed_at" "$max_age")"; then
    fail_section invalid "logical backup manifest has an unusable createdAt"
    return 0
  fi
  base="$($JQ_BIN -nc --argjson base "$base" --arg generation "$generation" '$base + {generation:$generation}')"

  extra='{}'
  dumps_file="$target/metadata/dumps.json"
  if [[ -s "$dumps_file" ]]; then
    extra="$($JQ_BIN -cs '
      .[0] as $d
      | if ($d | type) == "object" then
          {
            expected: (($d.expected // []) | if type == "array" then .[0:64] else [] end),
            dumps: (($d.dumps // []) | if type == "array" then .[0:64] else [] end)
          }
        else {} end
    ' "$dumps_file" 2>/dev/null || printf '{}')"
  fi
  $JQ_BIN -nc --argjson base "$base" --argjson extra "$extra" '$base + $extra'
}

offsite_section() {
  local file="$1" max_age="$2" state timestamp message reason bytes limit epoch age
  if [[ -z "$file" ]]; then
    printf '{"disabled":true}\n'
    return 0
  fi
  if [[ ! -s "$file" ]]; then
    fail_section missing "no offsite mirror run has been recorded yet"
    return 0
  fi
  if ! state="$($JQ_BIN -er '.state | select(type == "string" and length > 0)' "$file" 2>/dev/null)"; then
    fail_section invalid "offsite mirror status has no state"
    return 0
  fi
  timestamp="$($JQ_BIN -r '.timestamp // empty' "$file" 2>/dev/null || true)"
  message="$($JQ_BIN -r '.message // empty' "$file" 2>/dev/null || true)"
  reason="$($JQ_BIN -r '.reason // empty' "$file" 2>/dev/null || true)"
  bytes="$($JQ_BIN -r '.repositoryBytes // 0' "$file" 2>/dev/null || true)"
  limit="$($JQ_BIN -r '.limitBytes // 0' "$file" 2>/dev/null || true)"
  [[ "$bytes" =~ ^[0-9]+$ ]] || bytes=0
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=0

  age=null
  if [[ "$timestamp" =~ $timestamp_pattern ]] || [[ -n "$timestamp" ]]; then
    if epoch="$($DATE_BIN --date "$timestamp" +%s 2>/dev/null)" && [[ "$epoch" =~ ^[0-9]+$ ]]; then
      age=$((now - epoch))
      (( age >= 0 )) || age=0
    fi
  fi

  $JQ_BIN -nc \
    --arg state "$state" \
    --arg reason "$reason" \
    --arg message "$message" \
    --arg completedAt "$timestamp" \
    --argjson ageSeconds "$age" \
    --argjson maxAgeSeconds "$max_age" \
    --argjson repositoryBytes "$bytes" \
    --argjson limitBytes "$limit" \
    '{
      state:$state,
      reason:$reason,
      message:$message,
      completedAt:$completedAt,
      ageSeconds:$ageSeconds,
      maxAgeSeconds:$maxAgeSeconds,
      repositoryBytes:$repositoryBytes,
      limitBytes:$limitBytes
    }'
}

# Attribute overlap with storage-monitoring.nix is intentional: both read the
# same automatic snapshots. Here a degraded pool or stale dataset is data to
# render, so nothing fails the collection job.
zfs_section() {
  local pool="$1" max_age="$2" health managed stale newest_age dataset enabled
  if [[ -z "$pool" ]]; then
    printf '{"disabled":true}\n'
    return 0
  fi
  if ! health="$($ZPOOL_BIN list -H -o health "$pool" 2>/dev/null)" || [[ -z "$health" ]]; then
    fail_section unavailable "the ZFS pool health could not be read"
    return 0
  fi

  managed=0
  stale=0
  newest_age=null
  while IFS=$'\t' read -r dataset enabled; do
    [[ "$enabled" == true ]] || continue
    [[ "$($ZFS_BIN get -H -o value mounted "$dataset" 2>/dev/null || true)" == yes ]] || continue
    managed=$((managed + 1))
    local newest_epoch age
    newest_epoch="$($ZFS_BIN list -H -p -d 1 -t snapshot -o creation,name -s creation "$dataset" 2>/dev/null || true)"
    newest_epoch="$(
      printf '%s\n' "$newest_epoch" |
        awk '$2 ~ /@zfs-auto-snap_/ { print $1 }' | tail -n 1
    )"
    if [[ ! "$newest_epoch" =~ ^[0-9]+$ ]]; then
      stale=$((stale + 1))
      continue
    fi
    age=$((now - newest_epoch))
    (( age >= 0 )) || age=0
    if [[ "$newest_age" == null ]] || (( age < newest_age )); then
      newest_age=$age
    fi
    if (( age > max_age )); then
      stale=$((stale + 1))
    fi
  done < <($ZFS_BIN get -H -o name,value -t filesystem -r com.sun:auto-snapshot "$pool" 2>/dev/null || true)

  $JQ_BIN -nc \
    --arg pool "$pool" \
    --arg health "$health" \
    --argjson managedDatasets "$managed" \
    --argjson staleDatasets "$stale" \
    --argjson newestAgeSeconds "$newest_age" \
    --argjson maxAgeSeconds "$max_age" \
    '{
      pool:$pool,
      health:$health,
      managedDatasets:$managedDatasets,
      staleDatasets:$staleDatasets,
      newestAgeSeconds:$newestAgeSeconds,
      maxAgeSeconds:$maxAgeSeconds
    }'
}

output_dir="$($DIRNAME_BIN -- "$output")"
[[ -d "$output_dir" ]] || { echo "Output directory does not exist: $output_dir" >&2; exit 73; }

kopia_snapshot_json="$(marker_section "$kopia_snapshot_marker" "${kopia_snapshot_max_age:-1}")"
kopia_verify_json="$(marker_section "$kopia_verify_marker" "${kopia_verify_max_age:-1}")"
logical_json="$(logical_section "$logical_current_link" "${logical_max_age:-1}")"
offsite_json="$(offsite_section "$offsite_status_file" "${offsite_max_age:-1}")"
zfs_json="$(zfs_section "$zfs_pool" "${zfs_max_age:-1}")"

umask 0077
status_tmp="$($MKTEMP_BIN "$output_dir/.status.XXXXXX")"
cleanup() {
  [[ -z "${status_tmp:-}" ]] || "$RM_BIN" -f -- "$status_tmp"
}
trap cleanup EXIT

generated_at="$($DATE_BIN --utc --date "@$now" --iso-8601=seconds)"
$JQ_BIN -n \
  --arg generatedAt "$generated_at" \
  --argjson kopiaSnapshot "$kopia_snapshot_json" \
  --argjson kopiaVerify "$kopia_verify_json" \
  --argjson logicalBackup "$logical_json" \
  --argjson offsiteSync "$offsite_json" \
  --argjson zfsSnapshots "$zfs_json" \
  '{
    schemaVersion:1,
    generatedAt:$generatedAt,
    kopiaSnapshot:$kopiaSnapshot,
    kopiaVerify:$kopiaVerify,
    logicalBackup:$logicalBackup,
    offsiteSync:$offsiteSync,
    zfsSnapshots:$zfsSnapshots
  }' >"$status_tmp"

"$CHMOD_BIN" 0640 "$status_tmp"
if [[ -n "$output_group" ]]; then
  "$CHGRP_BIN" "$output_group" "$status_tmp"
fi
"$MV_BIN" -f -- "$status_tmp" "$output"
status_tmp=""
