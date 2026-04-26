{ pkgs, vars, ... }:

let
  jellyfinPort = 8096;
  dataDir = "/var/lib/jellyfin";
  dbPath = "${dataDir}/data/jellyfin.db";
  managedDir = "${dataDir}/.nixos-managed";
  desiredPasswordDir = "${managedDir}/desired-password-hashes";
  sharedJellyfinLibrariesJson = builtins.toJSON vars.sharedJellyfinLibraries;
  syncScript = pkgs.writeShellScript "jellyfin-reconcile-v1" ''
    set -euo pipefail

    managed_dir="${managedDir}"
    bootstrap_password_file="$managed_dir/admin-bootstrap-password"

    ${pkgs.coreutils}/bin/install -d -m 0700 "$managed_dir" '${desiredPasswordDir}'

    if [[ ! -f "$bootstrap_password_file" ]]; then
      ${pkgs.python3}/bin/python3 - <<'PY' > "$bootstrap_password_file"
import secrets
print(secrets.token_urlsafe(24))
PY
      chmod 0600 "$bootstrap_password_file"
    fi

    bootstrap_password="$(< "$bootstrap_password_file")"

    ensure_bootstrap_password() {
      local state
      state="$(${pkgs.python3}/bin/python3 - "${dbPath}" '${vars.kanidmAdminUser}' "$bootstrap_password" <<'PY'
import hashlib
import os
import sqlite3
import sys

db_path, username, password = sys.argv[1:]

def hash_password(value: str) -> str:
    salt = os.urandom(16)
    iterations = 210000
    derived = hashlib.pbkdf2_hmac("sha512", value.encode(), salt, iterations)
    return f"$PBKDF2-SHA512$iterations={iterations}$''${salt.hex().upper()}$''${derived.hex().upper()}"

def verify_password(value: str, stored: str | None) -> bool:
    if not stored or not stored.startswith("$PBKDF2-SHA512$"):
        return False
    parts = stored.split("$")
    if len(parts) != 5 or not parts[2].startswith("iterations="):
        return False
    iterations = int(parts[2].split("=", 1)[1])
    salt = bytes.fromhex(parts[3])
    expected = parts[4].upper()
    actual = hashlib.pbkdf2_hmac("sha512", value.encode(), salt, iterations).hex().upper()
    return actual == expected

connection = sqlite3.connect(db_path)
cursor = connection.cursor()
row = cursor.execute(
    "select Password from Users where Username = ? limit 1",
    (username,),
).fetchone()
if row is None:
    print("missing")
    sys.exit(0)
if verify_password(password, row[0]):
    print("unchanged")
    sys.exit(0)
cursor.execute(
    "update Users set Password = ?, InvalidLoginAttemptCount = 0, MustUpdatePassword = 0 where Username = ?",
    (hash_password(password), username),
)
connection.commit()
print("updated")
PY
)"

      case "$state" in
        unchanged)
          ;;
        updated)
          /run/current-system/sw/bin/systemctl restart jellyfin.service
          ;;
        missing)
          echo "Jellyfin admin user ${vars.kanidmAdminUser} does not exist yet" >&2
          exit 1
          ;;
        *)
          echo "Unexpected Jellyfin bootstrap password state: $state" >&2
          exit 1
          ;;
      esac
    }

    wait_for_jellyfin() {
      local status_json=""
      for _ in $(seq 1 60); do
        status_json="$(${pkgs.curl}/bin/curl --silent --show-error \
          "http://127.0.0.1:${toString jellyfinPort}/System/Info/Public" 2>/dev/null || true)"
        if [[ -n "$status_json" ]] \
          && printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -e '.StartupWizardCompleted != null' >/dev/null 2>&1; then
          return 0
        fi
        sleep 2
      done
      echo "Jellyfin did not become ready in time" >&2
      exit 1
    }

    authenticate_admin() {
      local auth_json=""
      local token=""
      for _ in $(seq 1 60); do
        auth_json="$(${pkgs.curl}/bin/curl --silent --show-error \
          -X POST \
          -H 'Content-Type: application/json' \
          -H 'X-Emby-Authorization: MediaBrowser Client="nixos-jellyfin-reconcile", Device="nixos-jellyfin-reconcile", DeviceId="nixos-jellyfin-reconcile", Version="1.0.0"' \
          --data "$(${pkgs.jq}/bin/jq -cn \
            --arg username '${vars.kanidmAdminUser}' \
            --arg password "$bootstrap_password" \
            '{ Username: $username, Pw: $password }')" \
          "http://127.0.0.1:${toString jellyfinPort}/Users/AuthenticateByName" 2>/dev/null || true)"
        token="$(printf '%s' "$auth_json" | ${pkgs.jq}/bin/jq -r '.AccessToken // empty' 2>/dev/null || true)"
        if [[ -n "$token" ]]; then
          printf '%s\n' "$token"
          return 0
        fi
        sleep 2
      done
      echo "Failed to authenticate the managed Jellyfin admin user" >&2
      exit 1
    }

    format_shared_library_name() {
      local label="$1"

      printf '%s (Shared)\n' "$label"
    }

    add_desired_library() {
      local name="$1"
      local collection_type="$2"
      local path="$3"

      [[ -d "$path" ]] || return 0
      printf '%s\t%s\t%s\n' "$name" "$collection_type" "$path" >> "$desired_libraries_file"
      printf '%s\n' "$name" >> "$desired_library_names_file"
    }

    urlencode() {
      ${pkgs.python3}/bin/python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
    }

    apply_staged_password_hashes() {
      ${pkgs.python3}/bin/python3 - "${dbPath}" '${desiredPasswordDir}' <<'PY'
import pathlib
import sqlite3
import sys

db_path = sys.argv[1]
password_dir = pathlib.Path(sys.argv[2])

connection = sqlite3.connect(db_path)
cursor = connection.cursor()

for path in sorted(password_dir.glob("*.pbkdf2")):
    username = path.stem
    password_hash = path.read_text(encoding="utf-8").strip()
    cursor.execute(
        "update Users set Password = ?, InvalidLoginAttemptCount = 0, MustUpdatePassword = 0 where Username = ?",
        (password_hash, username),
    )

connection.commit()
PY
    }

    update_user_deletion_policy() {
      local username="$1"
      local is_admin="$2"
      local deletion_ids_json="$3"
      local current=""
      local user_id=""
      local user_json=""
      local policy_json=""

      current="$(
        printf '%s' "$users_json" \
          | ${pkgs.jq}/bin/jq -c --arg username "$username" '.[] | select(.Name == $username)'
      )"
      [[ -n "$current" ]] || return 0

      user_id="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -r '.Id')"
      user_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
        -H "$auth_header" \
        "http://127.0.0.1:${toString jellyfinPort}/Users/$user_id")"

      policy_json="$(
        printf '%s' "$user_json" \
          | ${pkgs.jq}/bin/jq -c \
            --argjson deletion_ids "$deletion_ids_json" \
            --argjson is_admin "$is_admin" '
              .Policy
              | .EnableContentDeletionFromFolders = $deletion_ids
              | if has("EnableContentDeletion") then
                  .EnableContentDeletion = (($deletion_ids | length) > 0)
                else
                  .
                end
              | if $is_admin then
                  .IsAdministrator = true
                else
                  .
                end
            '
      )"

      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        --data "$policy_json" \
        "http://127.0.0.1:${toString jellyfinPort}/Users/$user_id/Policy" >/dev/null
    }

    ensure_bootstrap_password
    wait_for_jellyfin

    desired_libraries_file="$(mktemp)"
    desired_library_names_file="$(mktemp)"

    while IFS=$'\t' read -r dir label collection_type; do
      add_desired_library \
        "$(format_shared_library_name "$label")" \
        "$collection_type" \
        "${vars.sharedVideosRoot}/$dir"
    done < <(
      printf '%s' '${sharedJellyfinLibrariesJson}' \
        | ${pkgs.jq}/bin/jq -r '.[] | [ .dir, .label, .collectionType ] | @tsv'
    )

    token="$(authenticate_admin)"
    auth_header="Authorization: MediaBrowser Token=$token"

    libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders")"

    managed_current_names="$(
      printf '%s' "$libraries_json" \
        | ${pkgs.jq}/bin/jq -r --arg shared_root '${vars.sharedVideosRoot}' --arg users_root '${vars.usersWorkspaceRoot}' '
          .[]
          | select(
              ((.Locations // []) | length == 1)
              and (
                (.Locations[0] | startswith($shared_root + "/"))
                or (.Locations[0] | startswith($users_root + "/"))
              )
            )
          | .Name
        '
    )"

    while IFS= read -r current_name; do
      query=""
      [[ -n "$current_name" ]] || continue
      if ! ${pkgs.gnugrep}/bin/grep -Fxq "$current_name" "$desired_library_names_file"; then
        query="name=$(urlencode "$current_name")&refreshLibrary=true"
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X DELETE \
          -H "$auth_header" \
          "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders?$query" >/dev/null
      fi
    done <<< "$managed_current_names"

    libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders")"

    ensure_library() {
      local library_name="$1"
      local collection_type="$2"
      local library_path="$3"
      local current=""
      local current_locations=""
      local current_type=""
      local body='{}'
      local query=""

      current="$(
        printf '%s' "$libraries_json" \
          | ${pkgs.jq}/bin/jq -c --arg name "$library_name" '.[] | select(.Name == $name)'
      )"

      if [[ -n "$current" ]]; then
        current_type="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -r '.CollectionType // empty')"
        current_locations="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c '.Locations // []')"
        if [[ "$current_type" != "$collection_type" || "$current_locations" != "[\"$library_path\"]" ]]; then
          query="name=$(urlencode "$library_name")&refreshLibrary=true"
          ${pkgs.curl}/bin/curl --silent --show-error --fail \
            -X DELETE \
            -H "$auth_header" \
            "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders?$query" >/dev/null
          current=""
        fi
      fi

      if [[ -z "$current" ]]; then
        query="name=$(urlencode "$library_name")&collectionType=$(urlencode "$collection_type")&refreshLibrary=true&paths=$(urlencode "$library_path")"
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "$auth_header" \
          -H 'Content-Type: application/json' \
          --data "$body" \
          "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders?$query" >/dev/null
        libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          -H "$auth_header" \
          "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders")"
      fi

      printf '%s' "$libraries_json" \
        | ${pkgs.jq}/bin/jq -r --arg name "$library_name" '.[] | select(.Name == $name) | .ItemId'
    }

    declare -A library_ids=()
    while IFS=$'\t' read -r library_name collection_type library_path; do
      [[ -n "$library_name" && -n "$collection_type" && -n "$library_path" ]] || continue
      library_id="$(ensure_library "$library_name" "$collection_type" "$library_path")"
      [[ -n "$library_id" ]] || {
        echo "Unable to converge Jellyfin library '$library_name'" >&2
        exit 1
      }
      library_ids["$library_name"]="$library_id"
    done < "$desired_libraries_file"

    shared_deletion_ids_json="$(
      printf '%s\n' "''${library_ids[@]}" \
        | ${pkgs.jq}/bin/jq -Rsc 'split("\n") | map(select(length > 0)) | unique'
    )"

    apply_staged_password_hashes

    users_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "http://127.0.0.1:${toString jellyfinPort}/Users")"

    update_user_deletion_policy '${vars.kanidmAdminUser}' true "$shared_deletion_ids_json"

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      [[ "$username" == '${vars.kanidmAdminUser}' ]] && continue
      update_user_deletion_policy "$username" false '[]'
    done < <(
      printf '%s' "$users_json" | ${pkgs.jq}/bin/jq -r '.[].Name'
    )
  '';
in
{
  systemd.services.jellyfin-reconcile-v1 = {
    description = "Reconcile Jellyfin shared libraries and deletion policy";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "jellyfin.service"
      "data-pool-layout.service"
    ];
    after = [
      "jellyfin.service"
      "data-pool-layout.service"
    ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = dataDir;
    };
    script = ''
      ${syncScript}
    '';
  };

  systemd.timers.jellyfin-reconcile-v1 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00";
      Persistent = true;
    };
  };
}
