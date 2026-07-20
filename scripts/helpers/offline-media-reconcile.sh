#!/usr/bin/env bash

# Reconcile the persistent Homepage enrollment inventory with live Kanidm
# membership and Syncthing's runtime configuration.  The Nix module supplies
# all host-specific values through the OFFLINE_MEDIA_* environment variables.

set -euo pipefail
if [[ "${OFFLINE_MEDIA_TRACE:-0}" == 1 ]]; then
  set -x
fi

required_environment=(
  OFFLINE_MEDIA_ACCESS_GROUP
  OFFLINE_MEDIA_FOLDER_SPECS_JSON
  OFFLINE_MEDIA_KANIDM_PASSWORD_FILE
  OFFLINE_MEDIA_KANIDM_URL
  OFFLINE_MEDIA_STATE_FILE
  OFFLINE_MEDIA_SYNCTHING_CONFIG
  OFFLINE_MEDIA_USERS_ROOT
)
for variable_name in "${required_environment[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "offline media reconcile: missing required environment variable $variable_name" >&2
    exit 1
  fi
done

state_file="$OFFLINE_MEDIA_STATE_FILE"
state_dir="$(dirname "$state_file")"
lock_file="${OFFLINE_MEDIA_LOCK_FILE:-$state_dir/.devices.lock}"
api_base="${OFFLINE_MEDIA_API_BASE:-http://127.0.0.1:8384}"
state_owner="${OFFLINE_MEDIA_STATE_OWNER:-root}"
state_group="${OFFLINE_MEDIA_STATE_GROUP:-root}"

# Enrollment and explicit device removal take this same lock.  Holding it
# across the authoritative identity snapshot prevents a concurrent request
# from reintroducing state based on an older view of membership.
install -d -m 0750 -o "$state_owner" -g "$state_group" "$state_dir"
exec 9>"$lock_file"
flock -x 9

[[ -f "$state_file" ]] || exit 0

if ! state_json="$({ jq -cer '
    def valid_username:
      type == "string"
      and test("^[a-z][a-z0-9._-]{0,63}$");
    def valid_device:
      type == "object"
      and (.deviceId | type == "string" and test("^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$"))
      and (.deviceName | type == "string" and test("^[A-Za-z0-9._ -]{1,64}$"));
    if .version != 2 or ((.users // null) | type) != "object" then
      error("expected version 2 with an object-valued users field")
    elif ([.users | to_entries[] | select((.key | valid_username) | not)] | length) != 0 then
      error("invalid enrolled username")
    elif ([.users[] | select((.devices // null) | type != "array")] | length) != 0 then
      error("devices must be arrays")
    elif ([.users[].devices[] | select((valid_device) | not)] | length) != 0 then
      error("invalid enrolled device")
    else
      .
    end
  ' "$state_file"; } 2>/dev/null)"; then
  echo "offline media reconcile: enrollment state is invalid; refusing to change Syncthing or prune state" >&2
  exit 1
fi

temp_home="$(mktemp -d)"
api_key_file="$(mktemp)"
headers_file="$(mktemp)"
state_tmp=""
cleanup() {
  rm -rf "$temp_home"
  rm -f "$api_key_file" "$headers_file"
  if [[ -n "$state_tmp" ]]; then
    rm -f "$state_tmp"
  fi
}
trap cleanup EXIT

export HOME="$temp_home"
KANIDM_PASSWORD="$(< "$OFFLINE_MEDIA_KANIDM_PASSWORD_FILE")"
export KANIDM_PASSWORD

snapshot_group_members() {
  local group_name="$1"
  local group_json members_json

  if ! group_json="$(
    kanidm group get \
      "$group_name" \
      -H "$OFFLINE_MEDIA_KANIDM_URL" \
      -D idm_admin \
      -o json
  )"; then
    echo "offline media reconcile: unable to read Kanidm group '$group_name'; refusing to change Syncthing or enrollment state" >&2
    return 1
  fi
  if ! members_json="$(
    jq -cer '
      def local_username:
        split("@")[0] as $username
        | if ($username | test("^[a-z][a-z0-9._-]{0,63}$")) then
            $username
          else
            error("invalid local username in Kanidm member")
          end;
      if ((.attrs.member // []) | type) != "array" then
        error("Kanidm group member attribute is not an array")
      elif any(.attrs.member[]?; type != "string") then
        error("Kanidm group member array contains a non-string entry")
      else
        [ .attrs.member[]? | local_username ] | unique
      end
    ' <<<"$group_json"
  )"; then
    echo "offline media reconcile: Kanidm returned invalid membership for '$group_name'; refusing to change Syncthing or enrollment state" >&2
    return 1
  fi

  printf '%s\n' "$members_json"
}

# Resolve and validate every authoritative membership snapshot before the
# first Syncthing API call or persistent-state write.  Access is additive:
# every enrolled person needs baseline users membership and, when configured,
# the dedicated offline-media group.
kanidm login \
  -H "$OFFLINE_MEDIA_KANIDM_URL" \
  -D idm_admin >/dev/null
if ! baseline_members_json="$(snapshot_group_members users)"; then
  exit 1
fi
if [[ "$OFFLINE_MEDIA_ACCESS_GROUP" == "users" ]]; then
  access_members_json="$baseline_members_json"
elif ! access_members_json="$(snapshot_group_members "$OFFLINE_MEDIA_ACCESS_GROUP")"; then
  exit 1
fi

authorized_users_json="$(
  jq -cn \
    --argjson baseline "$baseline_members_json" \
    --argjson access "$access_members_json" \
    '[ $baseline[] | select(. as $username | $access | index($username) != null) ] | unique'
)"
state_users_json="$(jq -c '.users | keys' <<<"$state_json")"
active_users_json="$(
  jq -cn \
    --argjson state "$state_users_json" \
    --argjson authorized "$authorized_users_json" \
    '[ $state[] | select(. as $username | $authorized | index($username) != null) ]'
)"
stale_users_json="$(
  jq -cn \
    --argjson state "$state_users_json" \
    --argjson authorized "$authorized_users_json" \
    '[ $state[] | select(. as $username | $authorized | index($username) == null) ]'
)"
active_device_ids_json="$(
  jq -c \
    --argjson active "$active_users_json" \
    '[ $active[] as $username | .users[$username].devices[]?.deviceId ] | unique' \
    <<<"$state_json"
)"

xmllint \
  --xpath 'string(configuration/gui/apikey)' \
  "$OFFLINE_MEDIA_SYNCTHING_CONFIG" \
  >"$api_key_file"
if [[ ! -s "$api_key_file" ]]; then
  echo "offline media reconcile: Syncthing API key is unavailable" >&2
  exit 1
fi
{ printf 'X-API-Key: '; cat "$api_key_file"; } >"$headers_file"

api() {
  local path="$1"
  shift
  curl -fsSL \
    --connect-timeout 2 \
    --max-time 30 \
    -H "@$headers_file" \
    "$@" \
    "$api_base$path"
}

api_json() {
  local method="$1"
  local path="$2"
  local json="$3"

  printf '%s' "$json" | curl -fsSL \
    --connect-timeout 2 \
    --max-time 30 \
    -X "$method" \
    -H "@$headers_file" \
    -H 'content-type: application/json' \
    --data-binary @- \
    "$api_base$path" >/dev/null
}

restart_if_required() {
  if api /rest/config/restart-required | jq -e '.requiresRestart == true' >/dev/null; then
    systemctl restart syncthing.service
    api /rest/system/ping >/dev/null
  fi
}

api /rest/system/ping >/dev/null
folders_json="$(api /rest/config/folders)"
devices_json="$(api /rest/config/devices)"

# Validate every stale user's expected folder identity before detaching even
# one reference.  A reused or manually repointed folder ID is never touched.
while IFS= read -r username; do
  [[ -n "$username" ]] || continue
  while IFS=$'\t' read -r relative_path folder_id_prefix; do
    folder_id="$folder_id_prefix-$username"
    expected_path="$OFFLINE_MEDIA_USERS_ROOT/$username/$relative_path"
    folder_json="$(
      jq -c --arg folderId "$folder_id" \
        'first(.[] | select(.id == $folderId)) // empty' \
        <<<"$folders_json"
    )"
    if [[ -n "$folder_json" ]] \
      && [[ "$(jq -r '.path' <<<"$folder_json")" != "$expected_path" ]]; then
      echo "offline media reconcile: refusing unexpected path for stale folder $folder_id" >&2
      exit 1
    fi
  done < <(jq -r '.[] | [.relativePath, .folderIdPrefix] | @tsv' <<<"$OFFLINE_MEDIA_FOLDER_SPECS_JSON")
done < <(jq -r '.[]' <<<"$stale_users_json")

# Revocation is deliberately first.  API errors abort before devices.json is
# pruned, so the next timer run retries any partially completed detachments.
while IFS= read -r username; do
  [[ -n "$username" ]] || continue
  stale_device_ids_json="$(
    jq -c --arg username "$username" \
      '[.users[$username].devices[]?.deviceId] | unique' \
      <<<"$state_json"
  )"

  while IFS=$'\t' read -r relative_path folder_id_prefix; do
    folder_id="$folder_id_prefix-$username"
    folders_json="$(api /rest/config/folders)"
    folder_json="$(
      jq -c --arg folderId "$folder_id" \
        'first(.[] | select(.id == $folderId)) // empty' \
        <<<"$folders_json"
    )"
    [[ -n "$folder_json" ]] || continue

    detached_folder="$(
      jq --argjson staleDevices "$stale_device_ids_json" '
        .devices = ((.devices // []) | map(select(.deviceID as $id | $staleDevices | index($id) == null)))
      ' <<<"$folder_json"
    )"
    if [[ "$(jq -cS . <<<"$folder_json")" == "$(jq -cS . <<<"$detached_folder")" ]]; then
      continue
    fi
    if [[ "$(jq '.devices | length' <<<"$detached_folder")" == "0" ]]; then
      api "/rest/config/folders/$folder_id" -X DELETE >/dev/null
    else
      api_json POST /rest/config/folders "$detached_folder"
    fi
  done < <(jq -r '.[] | [.relativePath, .folderIdPrefix] | @tsv' <<<"$OFFLINE_MEDIA_FOLDER_SPECS_JSON")
done < <(jq -r '.[]' <<<"$stale_users_json")

stale_device_ids_json="$(
  jq -c \
    --argjson stale "$stale_users_json" \
    '[ $stale[] as $username | .users[$username].devices[]?.deviceId ] | unique' \
    <<<"$state_json"
)"
folders_json="$(api /rest/config/folders)"
devices_json="$(api /rest/config/devices)"
while IFS= read -r device_id; do
  [[ -n "$device_id" ]] || continue
  if jq -e --arg deviceId "$device_id" 'index($deviceId) != null' \
      <<<"$active_device_ids_json" >/dev/null; then
    continue
  fi
  remaining_refs="$(
    jq --arg deviceId "$device_id" \
      '[.[].devices[]? | select(.deviceID == $deviceId)] | length' \
      <<<"$folders_json"
  )"
  if [[ "$remaining_refs" == "0" ]] \
    && jq -e --arg deviceId "$device_id" 'any(.[]; .deviceID == $deviceId)' \
      <<<"$devices_json" >/dev/null; then
    api "/rest/config/devices/$device_id" -X DELETE >/dev/null
  fi
done < <(jq -r '.[]' <<<"$stale_device_ids_json")

if [[ "$(jq 'length' <<<"$stale_users_json")" != "0" ]]; then
  restart_if_required
  state_tmp="$(mktemp "$state_dir/.devices.XXXXXX")"
  jq --argjson stale "$stale_users_json" '
    reduce $stale[] as $username (. ; del(.users[$username]))
  ' <<<"$state_json" >"$state_tmp"
  chmod 0640 "$state_tmp"
  chown "$state_owner:$state_group" "$state_tmp"
  mv "$state_tmp" "$state_file"
  state_tmp=""
  state_json="$(jq -c . "$state_file")"
fi

# Revocation is now durable.  Converge the remaining authorized enrollments,
# including recreation after the disabled-state cleanup removed managed
# Syncthing folders and globally unreferenced peers.
active_preflight_failed=0
folders_json="$(api /rest/config/folders)"
while IFS= read -r username; do
  [[ -n "$username" ]] || continue
  while IFS=$'\t' read -r relative_path folder_id_prefix; do
    folder_id="$folder_id_prefix-$username"
    expected_path="$OFFLINE_MEDIA_USERS_ROOT/$username/$relative_path"
    folder_json="$(
      jq -c --arg folderId "$folder_id" \
        'first(.[] | select(.id == $folderId)) // empty' \
        <<<"$folders_json"
    )"
    if [[ -n "$folder_json" ]] \
      && [[ "$(jq -r '.path' <<<"$folder_json")" != "$expected_path" ]]; then
      echo "offline media reconcile: refusing unexpected path for $folder_id" >&2
      active_preflight_failed=1
    elif [[ ! -d "$expected_path" ]]; then
      echo "offline media reconcile: source folder is missing: $expected_path" >&2
      active_preflight_failed=1
    elif ! runuser -u syncthing -- test -r "$expected_path/.stfolder"; then
      echo "offline media reconcile: Syncthing cannot traverse $expected_path" >&2
      active_preflight_failed=1
    else
      if ! unreadable="$(
        runuser -u syncthing -- \
          find "$expected_path" -type f ! -readable -print -quit
      )"; then
        echo "offline media reconcile: Syncthing cannot fully traverse $expected_path; check nested directory permissions" >&2
        active_preflight_failed=1
      elif [[ -n "$unreadable" ]]; then
        echo "offline media reconcile: Syncthing cannot read: $unreadable" >&2
        active_preflight_failed=1
      fi
    fi
  done < <(jq -r '.[] | [.relativePath, .folderIdPrefix] | @tsv' <<<"$OFFLINE_MEDIA_FOLDER_SPECS_JSON")
done < <(jq -r '.[]' <<<"$active_users_json")
if (( active_preflight_failed != 0 )); then
  exit 1
fi

default_device_json="$(api /rest/config/defaults/device)"
default_folder_json="$(api /rest/config/defaults/folder)"
devices_json="$(api /rest/config/devices)"
while IFS= read -r username; do
  [[ -n "$username" ]] || continue
  enrolled_devices_json="$(
    jq -c --arg username "$username" \
      '[.users[$username].devices[]?.deviceId] | unique' \
      <<<"$state_json"
  )"

  while IFS=$'\t' read -r device_id device_name; do
    [[ -n "$device_id" ]] || continue
    if ! jq -e --arg deviceId "$device_id" 'any(.[]; .deviceID == $deviceId)' \
        <<<"$devices_json" >/dev/null; then
      device_json="$(
        jq \
          --arg deviceId "$device_id" \
          --arg deviceName "$device_name" '
            .deviceID = $deviceId
            | .name = $deviceName
            | .addresses = ((.addresses // []) | if length > 0 then . else ["dynamic"] end)
          ' <<<"$default_device_json"
      )"
      api_json POST /rest/config/devices "$device_json"
      devices_json="$(api /rest/config/devices)"
    fi
  done < <(jq -r --arg username "$username" \
    '.users[$username].devices[]? | [.deviceId, .deviceName] | @tsv' \
    <<<"$state_json")

  while IFS=$'\t' read -r label relative_path folder_id_prefix; do
    folder_id="$folder_id_prefix-$username"
    folder_path="$OFFLINE_MEDIA_USERS_ROOT/$username/$relative_path"
    folders_json="$(api /rest/config/folders)"
    folder_json="$(
      jq -c --arg folderId "$folder_id" \
        'first(.[] | select(.id == $folderId)) // empty' \
        <<<"$folders_json"
    )"
    if [[ -z "$folder_json" ]]; then
      folder_json="$default_folder_json"
    fi
    repaired_folder="$(
      jq \
        --arg folderId "$folder_id" \
        --arg label "NixHomeServer $label - $username" \
        --arg path "$folder_path" \
        --argjson enrolled "$enrolled_devices_json" '
          .id = $folderId
          | .label = $label
          | .path = $path
          | .type = "sendonly"
          | .paused = false
          | .fsWatcherEnabled = true
          | .rescanIntervalS = 300
          | .devices = (
              (.devices // []) as $current
              | ((($current | map(.deviceID)) + $enrolled) | unique)
              | map(. as $id | (first($current[] | select(.deviceID == $id)) // {deviceID: $id}))
            )
        ' <<<"$folder_json"
    )"
    if [[ "$(jq -cS . <<<"$folder_json")" != "$(jq -cS . <<<"$repaired_folder")" ]]; then
      api_json POST /rest/config/folders "$repaired_folder"
      echo "offline media reconcile: converged Syncthing folder $folder_id"
    fi
    api "/rest/db/scan?folder=$folder_id" -X POST >/dev/null
    folder_status="$(api "/rest/db/status?folder=$folder_id")"
    folder_error="$(jq -r '.error // ""' <<<"$folder_status")"
    if [[ -n "$folder_error" ]]; then
      echo "offline media reconcile: $folder_id is in error: $folder_error" >&2
      exit 1
    fi
  done < <(jq -r '.[] | [.label, .relativePath, .folderIdPrefix] | @tsv' \
    <<<"$OFFLINE_MEDIA_FOLDER_SPECS_JSON")
done < <(jq -r '.[]' <<<"$active_users_json")

restart_if_required
connections_json="$(api /rest/system/connections)"
device_stats_json="$(api /rest/stats/device)"
while IFS=$'\t' read -r device_id device_name; do
  [[ -n "$device_id" ]] || continue
  connected="$(jq -r --arg id "$device_id" '.connections[$id].connected // false' <<<"$connections_json")"
  if [[ "$connected" != true ]]; then
    last_seen="$(jq -r --arg id "$device_id" '.[$id].lastSeen // "never"' <<<"$device_stats_json")"
    echo "offline media reconcile: device '$device_name' is offline; last seen $last_seen" >&2
  fi
done < <(jq -r \
  --argjson active "$active_users_json" \
  '[ $active[] as $username | .users[$username].devices[]? ] | unique_by(.deviceId)[] | [.deviceId, .deviceName] | @tsv' \
  <<<"$state_json")
