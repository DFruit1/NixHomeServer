{ config, lib, pkgs, vars, ... }:

let
  audiobookshelfPort = 13378;
  kanidmPort = 8443;
  dataDir = "/var/lib/audiobookshelf";
  managedDir = "/var/lib/audiobookshelf/.nixos-managed";
  syncScript = pkgs.writeShellScript "audiobookshelf-library-sync-v1" ''
    set -euo pipefail

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

    login_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs >/dev/null

      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        audiobookshelf-users \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    admin_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        audiobookshelf-admin \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    bootstrap_password="$(< ${config.age.secrets.absBootstrapPass.path})"
    token="$(
      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        -H 'Content-Type: application/json' \
        --data "$(${pkgs.jq}/bin/jq -cn \
          --arg username '${vars.kanidmAdminUser}' \
          --arg password "$bootstrap_password" \
          '{ username: $username, password: $password }')" \
        "http://127.0.0.1:${toString audiobookshelfPort}/login" \
        | ${pkgs.jq}/bin/jq -r '.user.token'
    )"
    [[ -n "$token" && "$token" != "null" ]] || {
      echo "Failed to obtain an Audiobookshelf API token" >&2
      exit 1
    }

    library_names_file="$(mktemp)"
    desired_users_file="$(mktemp)"
    library_spec_file="$(mktemp)"

    printf 'Shared Audiobooks\t${vars.sharedAudiobooksRoot}\n' > "$library_spec_file"
    printf 'Shared Audiobooks\n' > "$library_names_file"

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      printf '%s\n' "$username" >> "$desired_users_file"
      personal_path="${vars.usersWorkspaceRoot}/$username/audiobooks"
      if [[ -d "$personal_path" ]]; then
        printf '%s Audiobooks\t%s\n' "$username" "$personal_path" >> "$library_spec_file"
        printf '%s Audiobooks\n' "$username" >> "$library_names_file"
      fi
    done < <(
      printf '%s' "$login_group_json" \
        | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
        | ${pkgs.coreutils}/bin/sort -u
    )

    libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "Authorization: Bearer $token" \
      "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries")"
    users_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "Authorization: Bearer $token" \
      "http://127.0.0.1:${toString audiobookshelfPort}/api/users")"

    changed=0

    ensure_library() {
      local library_name="$1"
      local library_path="$2"
      local existing
      local library_id

      existing="$(
        printf '%s' "$libraries_json" \
          | ${pkgs.jq}/bin/jq -c --arg name "$library_name" '.libraries[]? | select(.name == $name)'
      )"

      if [[ -z "$existing" ]]; then
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "$(${pkgs.jq}/bin/jq -cn \
            --arg name "$library_name" \
            --arg path "$library_path" \
            '{
              name: $name,
              folders: [{ fullPath: $path }],
              icon: "audiobookshelf",
              mediaType: "book",
              provider: "audible"
            }')" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries" >/dev/null
        changed=1
        libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          -H "Authorization: Bearer $token" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries")"
        existing="$(
          printf '%s' "$libraries_json" \
            | ${pkgs.jq}/bin/jq -c --arg name "$library_name" '.libraries[]? | select(.name == $name)'
        )"
      fi

      [[ -n "$existing" ]] || {
        echo "Unable to converge Audiobookshelf library '$library_name'" >&2
        exit 1
      }

      if [[ "$(
        printf '%s' "$existing" \
          | ${pkgs.jq}/bin/jq -r '.folders[0].fullPath // empty'
      )" != "$library_path" ]]; then
        local updated
        library_id="$(
          printf '%s' "$existing" \
            | ${pkgs.jq}/bin/jq -r '.id'
        )"
        updated="$(
          printf '%s' "$existing" \
            | ${pkgs.jq}/bin/jq -c --arg path "$library_path" '.folders = [{ fullPath: $path }]'
        )"
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X PATCH \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "$updated" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries/$library_id" >/dev/null
        changed=1
        libraries_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          -H "Authorization: Bearer $token" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries")"
        existing="$(
          printf '%s' "$libraries_json" \
            | ${pkgs.jq}/bin/jq -c --arg name "$library_name" '.libraries[]? | select(.name == $name)'
        )"
      fi

      library_id="$(
        printf '%s' "$existing" \
          | ${pkgs.jq}/bin/jq -r '.id'
      )"
      printf '%s\n' "$library_id"
    }

    declare -A library_ids=()
    while IFS=$'\t' read -r library_name library_path; do
      [[ -n "$library_name" && -n "$library_path" ]] || continue
      library_ids["$library_name"]="$(ensure_library "$library_name" "$library_path")"
    done < "$library_spec_file"

    admin_users="$(
      printf '%s' "$admin_group_json" \
        | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
        | ${pkgs.coreutils}/bin/sort -u
    )"

    update_user_access() {
      local username="$1"
      local allowed_json="$2"
      local mode="$3"
      local current
      local user_id
      local user_type
      local payload

      current="$(
        printf '%s' "$users_json" \
          | ${pkgs.jq}/bin/jq -c --arg username "$username" '.users[]? | select(.username == $username)'
      )"
      [[ -n "$current" ]] || return 0

      user_id="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -r '.id')"
      user_type="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -r '.type')"

      if [[ "$user_type" == "root" ]]; then
        return 0
      fi

      if [[ "$mode" == "admin" ]]; then
        payload="$(
          ${pkgs.jq}/bin/jq -cn \
            --argjson current "$current" '
              {
                username: $current.username,
                email: $current.email,
                type: "admin",
                isActive: $current.isActive,
                permissions: (($current.permissions // {}) | .accessAllLibraries = true),
                librariesAccessible: [],
                itemTagsSelected: ($current.itemTagsSelected // [])
              }
            '
        )"
      else
        payload="$(
          ${pkgs.jq}/bin/jq -cn \
            --argjson current "$current" \
            --argjson libraries "$allowed_json" '
              {
                username: $current.username,
                email: $current.email,
                type: "user",
                isActive: $current.isActive,
                permissions: (($current.permissions // {}) | .accessAllLibraries = false),
                librariesAccessible: $libraries,
                itemTagsSelected: ($current.itemTagsSelected // [])
              }
            '
        )"
      fi

      if [[ "$payload" != "$current" ]]; then
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X PATCH \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "$payload" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/users/$user_id" >/dev/null
        changed=1
      fi
    }

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      if printf '%s\n' "$admin_users" | ${pkgs.gnugrep}/bin/grep -Fxq "$username"; then
        update_user_access "$username" '[]' admin
        continue
      fi

      allowed_ids=("''${library_ids["Shared Audiobooks"]}")
      if [[ -n "''${library_ids["$username Audiobooks"]:-}" ]]; then
        allowed_ids+=("''${library_ids["$username Audiobooks"]}")
      fi
      allowed_json="$(
        printf '%s\n' "''${allowed_ids[@]}" \
          | ${pkgs.jq}/bin/jq -Rcs 'split("\n") | map(select(length > 0))'
      )"
      update_user_access "$username" "$allowed_json" user
    done < "$desired_users_file"

    if [[ "$changed" -eq 1 ]]; then
      while IFS= read -r library_name; do
        [[ -n "$library_name" ]] || continue
        library_id="''${library_ids["$library_name"]:-}"
        [[ -n "$library_id" ]] || continue
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "Authorization: Bearer $token" \
          "http://127.0.0.1:${toString audiobookshelfPort}/api/libraries/$library_id/scan?force=0" >/dev/null
      done < "$library_names_file"
    fi
  '';
in
{
  systemd.services.audiobookshelf-library-sync-v1 = {
    description = "Synchronize Audiobookshelf managed personal and shared libraries";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "audiobookshelf.service"
      "audiobookshelf-oidc-bootstrap-v1.service"
      "audiobookshelf-root-bootstrap-v1.service"
      "data-pool-layout.service"
      "fileshare-workspace-sync.service"
      "kanidm.service"
    ];
    after = [
      "audiobookshelf.service"
      "audiobookshelf-oidc-bootstrap-v1.service"
      "audiobookshelf-root-bootstrap-v1.service"
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
      install -d -m 0750 ${managedDir}
      ${syncScript}
    '';
  };

  systemd.timers.audiobookshelf-library-sync-v1 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00";
      Persistent = true;
    };
  };
}
