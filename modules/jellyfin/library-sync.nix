{ config, pkgs, vars, ... }:

let
  jellyfinPort = 8096;
  kanidmPort = 8443;
  dataDir = "/var/lib/jellyfin";
  managedDir = "${dataDir}/.nixos-managed";
  personalJellyfinLibrariesJson = builtins.toJSON vars.personalJellyfinLibraries;
  sharedJellyfinLibrariesJson = builtins.toJSON vars.sharedJellyfinLibraries;
  syncScript = pkgs.writeShellScript "jellyfin-library-sync-v1" ''
    set -euo pipefail

    managed_dir="${managedDir}"
    bootstrap_password_file="$managed_dir/admin-bootstrap-password"

    [[ -f "$bootstrap_password_file" ]] || {
      echo "Jellyfin bootstrap password file is missing; run jellyfin-user-sync-v1 first" >&2
      exit 1
    }
    bootstrap_password="$(< "$bootstrap_password_file")"

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
          -H 'X-Emby-Authorization: MediaBrowser Client="nixos-jellyfin-library-sync", Device="nixos-jellyfin-library-sync", DeviceId="nixos-jellyfin-library-sync", Version="1.0.0"' \
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

    wait_for_jellyfin

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

    login_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs >/dev/null

      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        jellyfin-users \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    admin_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        jellyfin-admin \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    login_users_file="$(mktemp)"
    admin_users_file="$(mktemp)"
    desired_users_file="$(mktemp)"
    desired_libraries_file="$(mktemp)"
    desired_library_names_file="$(mktemp)"

    printf '%s' "$login_group_json" \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u > "$login_users_file"

    printf '%s' "$admin_group_json" \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u > "$admin_users_file"

    cat "$login_users_file" "$admin_users_file" | ${pkgs.coreutils}/bin/sort -u > "$desired_users_file"

    format_personal_library_name() {
      local username="$1"
      local label="$2"

      printf '%s (%s)\n' "$label" "$username"
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

    while IFS=$'\t' read -r dir label collection_type; do
      add_desired_library \
        "$(format_shared_library_name "$label")" \
        "$collection_type" \
        "${vars.sharedVideosRoot}/$dir"
    done < <(
      printf '%s' '${sharedJellyfinLibrariesJson}' \
        | ${pkgs.jq}/bin/jq -r '.[] | [ .dir, .label, .collectionType ] | @tsv'
    )

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      while IFS=$'\t' read -r dir label collection_type; do
        add_desired_library \
          "$(format_personal_library_name "$username" "$label")" \
          "$collection_type" \
          "${vars.usersWorkspaceRoot}/$username/videos/$dir"
      done < <(
        printf '%s' '${personalJellyfinLibrariesJson}' \
          | ${pkgs.jq}/bin/jq -r '.[] | [ .dir, .label, .collectionType ] | @tsv'
      )
    done < "$desired_users_file"

    token="$(authenticate_admin)"
    auth_header="Authorization: MediaBrowser Token=$token"

    urlencode() {
      ${pkgs.python3}/bin/python3 - "$1" <<'PY'
import sys
from urllib.parse import quote
print(quote(sys.argv[1], safe=""))
PY
    }

    libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "http://127.0.0.1:${toString jellyfinPort}/Library/VirtualFolders")"
    users_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "http://127.0.0.1:${toString jellyfinPort}/Users")"

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
      local current
      local current_locations
      local current_type
      local body='{}'
      local query

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

    update_user_policy() {
      local username="$1"
      local mode="$2"
      local allowed_json="$3"
      local current
      local user_id
      local user_json
      local policy_json

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
            --argjson is_admin "$([ "$mode" = admin ] && echo true || echo false)" \
            --argjson allowed "$allowed_json" '
              .Policy
              | .IsAdministrator = $is_admin
              | .EnableAllFolders = false
              | .EnabledFolders = $allowed
            '
      )"

      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        --data "$policy_json" \
        "http://127.0.0.1:${toString jellyfinPort}/Users/$user_id/Policy" >/dev/null
    }

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      allowed_json="$(
        {
          printf '%s' '${sharedJellyfinLibrariesJson}' \
            | ${pkgs.jq}/bin/jq -r '.[] | .label' \
            | while IFS= read -r label; do
              [[ -n "$label" ]] || continue
              format_shared_library_name "$label"
            done
          printf '%s' '${personalJellyfinLibrariesJson}' \
            | ${pkgs.jq}/bin/jq -r '.[] | .label' \
            | while IFS= read -r label; do
              [[ -n "$label" ]] || continue
              format_personal_library_name "$username" "$label"
            done
        } | while IFS= read -r library_name; do
          [[ -n "$library_name" ]] || continue
          library_id="''${library_ids["$library_name"]:-}"
          [[ -n "$library_id" ]] || continue
          printf '%s\n' "$library_id"
        done | ${pkgs.jq}/bin/jq -Rsc 'split("\n") | map(select(length > 0))'
      )"

      if ${pkgs.gnugrep}/bin/grep -Fxq "$username" "$admin_users_file"; then
        update_user_policy "$username" admin "$allowed_json"
        continue
      fi

      update_user_policy "$username" user "$allowed_json"
    done < "$desired_users_file"
  '';
in
{
  systemd.services.jellyfin-library-sync-v1 = {
    description = "Synchronize Jellyfin managed personal and shared libraries";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "jellyfin.service"
      "jellyfin-user-sync-v1.service"
      "data-pool-layout.service"
      "fileshare-workspace-sync.service"
      "kanidm.service"
    ];
    after = [
      "jellyfin.service"
      "jellyfin-user-sync-v1.service"
      "data-pool-layout.service"
      "fileshare-workspace-sync.service"
      "kanidm.service"
    ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      WorkingDirectory = dataDir;
    };
    script = ''
      ${pkgs.coreutils}/bin/install -d -m 0700 ${managedDir}
      ${syncScript}
    '';
  };

  systemd.timers.jellyfin-library-sync-v1 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00";
      Persistent = true;
    };
  };
}
