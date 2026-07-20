#!/usr/bin/env bash

# Remove only NixHomeServer-managed offline-media folders and unreferenced
# peers from Syncthing's persistent XML configuration while the feature is
# disabled or its optional module is absent.  Source media and devices.json
# are deliberately retained so a later re-enable can converge safely.

set -euo pipefail

required_environment=(
  OFFLINE_MEDIA_FOLDER_SPECS_JSON
  OFFLINE_MEDIA_STATE_FILE
  OFFLINE_MEDIA_SYNCTHING_CONFIG
  OFFLINE_MEDIA_USERS_ROOT
)
for variable_name in "${required_environment[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "offline media disabled cleanup: missing required environment variable $variable_name" >&2
    exit 1
  fi
done

config_file="$OFFLINE_MEDIA_SYNCTHING_CONFIG"
[[ -f "$config_file" ]] || exit 0

state_dir="$(dirname "$OFFLINE_MEDIA_STATE_FILE")"
lock_file="${OFFLINE_MEDIA_LOCK_FILE:-$state_dir/.devices.lock}"
state_owner="${OFFLINE_MEDIA_STATE_OWNER:-root}"
state_group="${OFFLINE_MEDIA_STATE_GROUP:-root}"
install -d -m 0750 -o "$state_owner" -g "$state_group" "$state_dir"
exec 9>"$lock_file"
flock -x 9

# A process from the previous generation may still have the persistent config
# open during a switch.  Stop it before taking the XML snapshot; never start a
# disabled Syncthing service merely to perform cleanup.
if systemctl is-active --quiet syncthing.service; then
  systemctl stop syncthing.service
fi

if ! xmllint --noout "$config_file"; then
  echo "offline media disabled cleanup: Syncthing config is invalid; refusing to edit it" >&2
  exit 1
fi

declare -a managed_folder_ids=()
declare -a candidate_device_ids=()
while IFS=$'\t' read -r folder_id folder_path; do
  [[ -n "$folder_id" ]] || continue
  matched=false
  while IFS=$'\t' read -r relative_path folder_id_prefix; do
    case "$folder_id" in
      "$folder_id_prefix"-*)
        username="${folder_id#"$folder_id_prefix"-}"
        if [[ ! "$username" =~ ^[a-z][a-z0-9._-]{0,63}$ ]]; then
          echo "offline media disabled cleanup: refusing malformed managed folder ID $folder_id" >&2
          exit 1
        fi
        expected_path="$OFFLINE_MEDIA_USERS_ROOT/$username/$relative_path"
        if [[ "$folder_path" != "$expected_path" ]]; then
          echo "offline media disabled cleanup: refusing unexpected path for $folder_id" >&2
          exit 1
        fi
        matched=true
        break
        ;;
    esac
  done < <(jq -r '.[] | [.relativePath, .folderIdPrefix] | @tsv' <<<"$OFFLINE_MEDIA_FOLDER_SPECS_JSON")

  if [[ "$matched" == true ]]; then
    managed_folder_ids+=("$folder_id")
    while IFS= read -r device_id; do
      [[ -n "$device_id" ]] || continue
      if [[ "$device_id" =~ ^[A-Z2-7]{7}(-[A-Z2-7]{7}){7}$ ]]; then
        candidate_device_ids+=("$device_id")
      fi
    done < <(xmlstarlet sel -t \
      -m "/configuration/folder[@id='$folder_id']/device" \
      -v '@id' -n "$config_file")
  fi
done < <(xmlstarlet sel -t -m '/configuration/folder' -v '@id' -o $'\t' -v '@path' -n "$config_file")

(( ${#managed_folder_ids[@]} > 0 )) || exit 0

config_dir="$(dirname "$config_file")"
temporary="$(mktemp "$config_dir/.offline-media-cleanup.XXXXXX")"
cleanup() {
  rm -f "$temporary"
}
trap cleanup EXIT
cp --preserve=mode,ownership "$config_file" "$temporary"

for folder_id in "${managed_folder_ids[@]}"; do
  xmlstarlet ed -L -d "/configuration/folder[@id='$folder_id']" "$temporary"
done

while IFS= read -r device_id; do
  [[ -n "$device_id" ]] || continue
  remaining_refs="$(xmlstarlet sel -t \
    -v "count(/configuration/folder/device[@id='$device_id'])" \
    "$temporary")"
  if [[ "$remaining_refs" == "0" ]]; then
    xmlstarlet ed -L \
      -d "/configuration/device[@id='$device_id']" \
      "$temporary"
  fi
done < <(printf '%s\n' "${candidate_device_ids[@]}" | sort -u)

xmllint --noout "$temporary"
mv "$temporary" "$config_file"
temporary=""
trap - EXIT
echo "offline media disabled cleanup: removed ${#managed_folder_ids[@]} managed Syncthing folder(s); source media and enrollment state were retained"
