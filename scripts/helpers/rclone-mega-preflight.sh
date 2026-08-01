#!/usr/bin/env bash

set -euo pipefail

: "${RCLONE_BIN:=rclone}"
: "${JQ_BIN:=jq}"
: "${SHA256SUM_BIN:=sha256sum}"
: "${CUT_BIN:=cut}"
: "${MKTEMP_BIN:=mktemp}"
: "${MV_BIN:=mv}"
: "${CHMOD_BIN:=chmod}"
: "${RM_BIN:=rm}"

config=""
source_path=""
cache_dir=""
checkers=""
always_transfer_from=""
remote_root=""
destination=""
marker_name=""
expected_fingerprint=""
repository_bytes=""
limit_bytes=""
control_reserve_bytes=1048576
result_file=""
state_dir=""

while (( $# > 0 )); do
  case "$1" in
    --config) config="${2:?--config requires a value}"; shift 2 ;;
    --source) source_path="${2:?--source requires a value}"; shift 2 ;;
    --cache-dir) cache_dir="${2:?--cache-dir requires a value}"; shift 2 ;;
    --checkers) checkers="${2:?--checkers requires a value}"; shift 2 ;;
    --always-transfer-from) always_transfer_from="${2:?--always-transfer-from requires a value}"; shift 2 ;;
    --remote-root) remote_root="${2:?--remote-root requires a value}"; shift 2 ;;
    --destination) destination="${2:?--destination requires a value}"; shift 2 ;;
    --marker-name) marker_name="${2:?--marker-name requires a value}"; shift 2 ;;
    --expected-fingerprint) expected_fingerprint="${2:?--expected-fingerprint requires a value}"; shift 2 ;;
    --repository-bytes) repository_bytes="${2:?--repository-bytes requires a value}"; shift 2 ;;
    --limit-bytes) limit_bytes="${2:?--limit-bytes requires a value}"; shift 2 ;;
    --control-reserve-bytes) control_reserve_bytes="${2:?--control-reserve-bytes requires a value}"; shift 2 ;;
    --result-file) result_file="${2:?--result-file requires a value}"; shift 2 ;;
    --state-dir) state_dir="${2:?--state-dir requires a value}"; shift 2 ;;
    *) echo "Unknown MEGA preflight argument: $1" >&2; exit 64 ;;
  esac
done

for required_value in config source_path cache_dir checkers always_transfer_from remote_root destination marker_name expected_fingerprint repository_bytes limit_bytes result_file state_dir; do
  [[ -n "${!required_value}" ]] || {
    echo "Missing required MEGA preflight value: $required_value" >&2
    exit 64
  }
done

write_result() {
  local failure_class="$1"
  local reason="$2"
  local message="$3"
  local retryable=false
  local operator_action_required=true
  local result_tmp

  case "$failure_class" in
    none) operator_action_required=false ;;
    transient) retryable=true; operator_action_required=false ;;
    capacity|safety|repository|remote) ;;
    *) echo "Invalid internal MEGA preflight class: $failure_class" >&2; exit 70 ;;
  esac

  result_tmp="$($MKTEMP_BIN "$(dirname "$result_file")/.mega-preflight-result.XXXXXX")"
  if ! "$JQ_BIN" -nc \
      --arg failureClass "$failure_class" \
      --arg reason "$reason" \
      --arg message "$message" \
      --argjson retryable "$retryable" \
      --argjson operatorActionRequired "$operator_action_required" \
      '{schemaVersion:1,failureClass:$failureClass,reason:$reason,message:$message,retryable:$retryable,operatorActionRequired:$operatorActionRequired}' \
      > "$result_tmp" \
    || ! "$CHMOD_BIN" 0600 "$result_tmp" \
    || ! "$MV_BIN" -f -- "$result_tmp" "$result_file"; then
    "$RM_BIN" -f -- "$result_tmp"
    return 73
  fi
}

preflight_fail() {
  local exit_code="$1"
  local failure_class="$2"
  local reason="$3"
  local message="$4"
  write_result "$failure_class" "$reason" "$message"
  echo "$message" >&2
  exit "$exit_code"
}

rclone_failure() {
  local rclone_exit="$1"
  local temporary_reason="$2"
  local failed_reason="$3"
  local message="$4"
  case "$rclone_exit" in
    3|4|5) preflight_fail 75 transient "$temporary_reason" "$message" ;;
    *) preflight_fail 78 remote "$failed_reason" "$message" ;;
  esac
}

identity_read_failure() {
  local rclone_exit="$1"
  local temporary_reason="$2"
  local message="$3"
  case "$rclone_exit" in
    3|4|5) preflight_fail 75 transient "$temporary_reason" "$message" ;;
    *) preflight_fail 77 safety remote_identity_unreadable "$message" ;;
  esac
}
[[ -r "$always_transfer_from" ]] || {
  echo "The always-transfer control-object list is not readable" >&2
  exit 64
}
[[ "$expected_fingerprint" =~ ^[0-9a-f]{64}$ ]] || {
  echo "Invalid expected Kopia repository fingerprint" >&2
  exit 64
}
for numeric_value in checkers repository_bytes limit_bytes control_reserve_bytes; do
  [[ "${!numeric_value}" =~ ^[0-9]+$ ]] || {
    echo "Invalid numeric MEGA preflight value: $numeric_value" >&2
    exit 64
  }
done

if (( repository_bytes >= limit_bytes )); then
  preflight_fail 76 capacity local_repository_limit \
    "The local repository reached the configured safety ceiling ($repository_bytes >= $limit_bytes bytes)"
fi

# Creating a missing directory is non-destructive and gives the listing a
# single unambiguous result for both a deleted destination and a new account.
"$RCLONE_BIN" mkdir --config "$config" "$destination" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" destination_create_temporary destination_create_failed \
    "MEGA destination cannot be created or opened; refusing destructive sync"
}
remote_listing="$($RCLONE_BIN lsf --config "$config" --max-depth 1 "$destination")" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" destination_list_temporary destination_list_failed \
    "MEGA destination cannot be listed; refusing destructive sync"
}

marker_present=false
identity_present=false
marker_count=0
identity_count=0
while IFS= read -r entry; do
  if [[ "$entry" == "$marker_name" ]]; then
    marker_present=true
    marker_count=$((marker_count + 1))
  fi
  if [[ "$entry" == "kopia.repository.f" ]]; then
    identity_present=true
    identity_count=$((identity_count + 1))
  fi
done <<< "$remote_listing"
(( marker_count <= 1 && identity_count <= 1 )) || {
  preflight_fail 77 safety duplicate_identity_objects \
    "The MEGA destination contains duplicate ownership or identity objects; refusing ambiguous destructive sync"
}

remote_marker="$destination/$marker_name"
adopt_marker=false
if [[ "$marker_present" == true ]]; then
  remote_marker_json="$($RCLONE_BIN cat --config "$config" "$remote_marker")" || {
    rclone_exit=$?
    if [[ "$rclone_exit" =~ ^(3|4|5)$ ]]; then
      preflight_fail 75 transient ownership_marker_read_temporary \
        "The MEGA ownership marker exists but cannot be read; refusing ambiguous destructive sync"
    fi
    preflight_fail 77 safety ownership_marker_unreadable \
      "The MEGA ownership marker exists but cannot be read; refusing ambiguous destructive sync"
  }
  "$JQ_BIN" -e \
    --arg repositoryFingerprint "$expected_fingerprint" \
    --arg destination "$destination" \
    '.schemaVersion == 1 and .repositoryFingerprint == $repositoryFingerprint and .destination == $destination' \
    <<< "$remote_marker_json" >/dev/null || {
    preflight_fail 77 safety ownership_marker_invalid \
      "The MEGA ownership marker is malformed or identifies another destination; refusing destructive sync"
  }

  # A missing identity object is a repairable deletion when the root-owned
  # marker still proves ownership. An identity object that exists must match.
  if [[ "$identity_present" == true ]]; then
    remote_fingerprint="$($RCLONE_BIN cat --config "$config" "$destination/kopia.repository.f" \
      | "$SHA256SUM_BIN" | "$CUT_BIN" -d ' ' -f 1)" || {
      rclone_exit=$?
      identity_read_failure "$rclone_exit" remote_identity_read_temporary \
        "The remote Kopia repository identity exists but cannot be read"
    }
    [[ "$remote_fingerprint" == "$expected_fingerprint" ]] || {
      preflight_fail 77 safety remote_identity_mismatch \
        "The owned MEGA destination contains a different Kopia repository identity; refusing destructive sync"
    }
  fi
elif [[ -n "$remote_listing" ]]; then
  [[ "$identity_present" == true ]] || {
    preflight_fail 77 safety ownership_proof_missing \
      "The non-empty MEGA destination has no ownership marker or Kopia identity; refusing ownership adoption"
  }
  remote_fingerprint="$($RCLONE_BIN cat --config "$config" "$destination/kopia.repository.f" \
    | "$SHA256SUM_BIN" | "$CUT_BIN" -d ' ' -f 1)" || {
    rclone_exit=$?
    identity_read_failure "$rclone_exit" remote_identity_read_temporary \
      "The markerless MEGA destination has no readable Kopia repository identity"
  }
  [[ "$remote_fingerprint" == "$expected_fingerprint" ]] || {
    preflight_fail 77 safety remote_identity_mismatch \
      "The markerless MEGA destination contains a different Kopia repository identity; refusing ownership adoption"
  }
  adopt_marker=true
else
  adopt_marker=true
fi

plan_dir="$($MKTEMP_BIN -d "$state_dir/.mega-transfer-plan.XXXXXX")"
marker_tmp=""
cleanup() {
  "$RM_BIN" -rf "$plan_dir"
  [[ -z "$marker_tmp" ]] || "$RM_BIN" -f "$marker_tmp"
}
trap cleanup EXIT
missing_destination="$plan_dir/missing-on-destination.txt"
different="$plan_dir/different.txt"
missing_source="$plan_dir/missing-on-source.txt"
plan_errors="$plan_dir/errors.txt"
: > "$missing_destination"
: > "$different"
: > "$missing_source"
: > "$plan_errors"

# MEGA uploads a changed object before hard-deleting its old node. Build the
# exact read-only sync plan so quota checks include that transient space while
# still crediting destination-only objects deleted before transfers begin.
"$RCLONE_BIN" sync \
  --config "$config" \
  --cache-dir "$cache_dir" \
  --dry-run \
  --retries 1 \
  --fast-list \
  --check-first \
  --delete-before \
  --mega-hard-delete \
  --exclude "/$marker_name" \
  --checkers "$checkers" \
  --missing-on-dst "$missing_destination" \
  --differ "$different" \
  --missing-on-src "$missing_source" \
  --error "$plan_errors" \
  "$source_path" \
  "$destination" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" transfer_plan_temporary transfer_plan_failed \
    "The read-only MEGA transfer plan failed; refusing destructive sync"
}
[[ ! -s "$plan_errors" ]] || {
  preflight_fail 78 remote transfer_plan_comparison_errors \
    "The read-only MEGA transfer plan found comparison errors; refusing destructive sync"
}

transfer_size_json="$($RCLONE_BIN size \
  --config "$config" \
  --json \
  --files-from "$missing_destination" \
  --files-from "$different" \
  "$source_path")" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" upload_size_temporary upload_size_failed \
    "The planned MEGA upload size cannot be calculated"
}
transfer_bytes="$($JQ_BIN -er '.bytes | select(type == "number" and floor == . and . >= 0)' <<< "$transfer_size_json")" || {
  preflight_fail 78 remote upload_size_invalid \
    "Rclone returned an invalid planned upload size"
}
control_size_json="$($RCLONE_BIN size \
  --config "$config" \
  --json \
  --files-from "$always_transfer_from" \
  "$source_path")" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" control_size_temporary control_size_failed \
    "The fixed-name Kopia control-object size cannot be calculated"
}
control_transfer_bytes="$($JQ_BIN -er '.bytes | select(type == "number" and floor == . and . >= 0)' <<< "$control_size_json")" || {
  preflight_fail 78 remote control_size_invalid \
    "Rclone returned an invalid control-object upload size"
}
delete_size_json="$($RCLONE_BIN size \
  --config "$config" \
  --json \
  --files-from "$missing_source" \
  "$destination")" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" deletion_size_temporary deletion_size_failed \
    "The pre-transfer MEGA deletion size cannot be calculated"
}
delete_bytes="$($JQ_BIN -er '.bytes | select(type == "number" and floor == . and . >= 0)' <<< "$delete_size_json")" || {
  preflight_fail 78 remote deletion_size_invalid \
    "Rclone returned an invalid pre-transfer deletion size"
}

quota_json="$($RCLONE_BIN about --config "$config" --json "$remote_root")" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" quota_read_temporary quota_read_failed \
    "MEGA live quota cannot be read; refusing destructive sync"
}
quota_fields="$($JQ_BIN -er '
  [.total // -1, .used // -1, .free // -1]
  | select(all(.[]; type == "number" and floor == . and . >= 0))
  | @tsv
' <<< "$quota_json")" || {
  preflight_fail 78 remote quota_invalid \
    "MEGA returned an invalid live quota; refusing destructive sync"
}
read -r total_bytes used_bytes free_bytes <<< "$quota_fields"
(( used_bytes <= total_bytes && free_bytes <= total_bytes )) || {
  preflight_fail 78 remote quota_inconsistent \
    "MEGA returned an inconsistent live quota; refusing destructive sync"
}

remote_size_json="$($RCLONE_BIN size --config "$config" --json "$destination")" || {
  rclone_exit=$?
  rclone_failure "$rclone_exit" destination_size_temporary destination_size_failed \
    "MEGA destination size cannot be read; refusing destructive sync"
}
remote_bytes="$($JQ_BIN -er '.bytes | select(type == "number" and floor == . and . >= 0)' <<< "$remote_size_json")" || {
  preflight_fail 78 remote destination_size_invalid \
    "MEGA returned an invalid destination size; refusing destructive sync"
}
(( remote_bytes <= used_bytes && delete_bytes <= remote_bytes )) || {
  preflight_fail 77 safety destination_size_inconsistent \
    "MEGA destination sizes are inconsistent with reported account usage; refusing ambiguous destructive sync"
}

capacity_ceiling="$limit_bytes"
(( total_bytes < capacity_ceiling )) && capacity_ceiling="$total_bytes"
projected_usage=$((used_bytes - remote_bytes + repository_bytes + control_reserve_bytes))
if (( projected_usage >= capacity_ceiling )); then
  preflight_fail 76 capacity projected_usage_limit \
    "The projected MEGA usage is $projected_usage bytes, at or above the $capacity_ceiling-byte safety ceiling (reported free: $free_bytes bytes)"
fi
available_upload_space=$((free_bytes + delete_bytes))
required_upload_space=$((transfer_bytes + control_transfer_bytes + control_reserve_bytes))
if (( required_upload_space > available_upload_space )); then
  preflight_fail 76 capacity insufficient_upload_space \
    "The planned uploads require $required_upload_space bytes but MEGA will have only $available_upload_space bytes after pre-transfer deletions"
fi
used_after_predeletes=$((used_bytes - delete_bytes))
transient_usage=$((used_after_predeletes + transfer_bytes + control_transfer_bytes + control_reserve_bytes))
if (( transient_usage >= capacity_ceiling )); then
  preflight_fail 76 capacity transient_usage_limit \
    "The transient MEGA usage would reach $transient_usage bytes, at or above the $capacity_ceiling-byte safety ceiling"
fi

if [[ "$adopt_marker" == true ]]; then
  marker_upload_usage=$((used_bytes + control_reserve_bytes))
  if (( marker_upload_usage >= capacity_ceiling )); then
    preflight_fail 76 capacity marker_upload_limit \
      "The ownership marker would reach $marker_upload_usage bytes, at or above the $capacity_ceiling-byte safety ceiling before pre-transfer deletions"
  fi
  marker_tmp="$($MKTEMP_BIN "$state_dir/.remote-owner.XXXXXX")"
  "$JQ_BIN" -n \
    --arg repositoryFingerprint "$expected_fingerprint" \
    --arg destination "$destination" \
    '{schemaVersion: 1, repositoryFingerprint: $repositoryFingerprint, destination: $destination}' \
    > "$marker_tmp"
  "$RCLONE_BIN" copyto --config "$config" "$marker_tmp" "$remote_marker" || {
    rclone_exit=$?
    rclone_failure "$rclone_exit" marker_upload_temporary marker_upload_failed \
      "The MEGA ownership marker could not be uploaded"
  }
fi

write_result none ready "MEGA preflight completed successfully."
