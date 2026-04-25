{ config, pkgs, vars, ... }:

let
  kavitaPort = 5000;
  kanidmPort = 8443;
  dataDir = "/var/lib/kavita";
  managedDir = "${dataDir}/.nixos-managed";
  syncScript = pkgs.writeShellScript "kavita-library-sync-v1" ''
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
        kavita-login \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    admin_group_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        kavita-admin \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    admin_api_key="$(${pkgs.sqlite}/bin/sqlite3 -readonly "${dataDir}/config/kavita.db" \
      "select ApiKey from AspNetUsers where UserName = '${vars.kanidmAdminUser}' limit 1;")"
    [[ -n "$admin_api_key" ]] || {
      echo "Kavita admin API key is missing for ${vars.kanidmAdminUser}" >&2
      exit 1
    }

    token="$(
      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        "http://127.0.0.1:${toString kavitaPort}/api/Plugin/authenticate?apiKey=$(${pkgs.jq}/bin/jq -rn --arg v "$admin_api_key" '$v|@uri' -r)&pluginName=nixos-kavita-library-sync-v1" \
        | ${pkgs.jq}/bin/jq -r '.token'
    )"
    [[ -n "$token" && "$token" != "null" ]] || {
      echo "Failed to obtain a Kavita API token" >&2
      exit 1
    }

    auth_header="Authorization: Bearer $token"
    api_url() {
      printf 'http://127.0.0.1:%s%s' '${toString kavitaPort}' "$1"
    }
    load_libraries_json() {
      ${pkgs.sqlite}/bin/sqlite3 -readonly "${dataDir}/config/kavita.db" <<'SQL'
.mode json
SELECT
  l.Id AS id,
  l.Name AS name,
  l.Type AS type,
  l.FolderWatching AS folderWatching,
  l.IncludeInDashboard AS includeInDashboard,
  l.IncludeInSearch AS includeInSearch,
  l.ManageCollections AS manageCollections,
  l.ManageReadingLists AS manageReadingLists,
  l.AllowScrobbling AS allowScrobbling,
  l.AllowMetadataMatching AS allowMetadataMatching,
  l.EnableMetadata AS enableMetadata,
  l.RemovePrefixForSortName AS removePrefixForSortName,
  COALESCE(
    (
      SELECT json_group_array(fp.Path)
      FROM FolderPath fp
      WHERE fp.LibraryId = l.Id
    ),
    json('[]')
  ) AS folders,
  COALESCE(
    (
      SELECT json_group_array(lftg.FileTypeGroup)
      FROM LibraryFileTypeGroup lftg
      WHERE lftg.LibraryId = l.Id
    ),
    json('[]')
  ) AS libraryFileTypes,
  COALESCE(
    (
      SELECT json_group_array(lep.Pattern)
      FROM LibraryExcludePattern lep
      WHERE lep.LibraryId = l.Id
    ),
    json('[]')
  ) AS excludePatterns
FROM Library l
ORDER BY l.Id;
SQL
    }

    login_users_file="$(mktemp)"
    admin_users_file="$(mktemp)"
    desired_users_file="$(mktemp)"
    desired_libraries_file="$(mktemp)"
    managed_library_names_file="$(mktemp)"

    printf '%s' "$login_group_json" \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u > "$login_users_file"

    printf '%s' "$admin_group_json" \
      | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
      | ${pkgs.coreutils}/bin/sort -u > "$admin_users_file"

    cat "$login_users_file" "$admin_users_file" | ${pkgs.coreutils}/bin/sort -u > "$desired_users_file"

    add_desired_library() {
      local name="$1"
      local type="$2"
      local path="$3"
      local groups_json="$4"

      [[ -d "$path" ]] || return 0
      printf '%s\t%s\t%s\t%s\n' "$name" "$type" "$path" "$groups_json" >> "$desired_libraries_file"
      printf '%s\n' "$name" >> "$managed_library_names_file"
    }

    add_desired_library 'Shared Ebooks' '2' '${vars.sharedEbooksRoot}' '[2,3,1]'
    add_desired_library 'Shared Comics' '1' '${vars.sharedComicsRoot}' '[1,4,3]'
    add_desired_library 'Shared Manga' '0' '${vars.sharedMangaRoot}' '[1,4]'

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      add_desired_library "$username Ebooks" '2' "${vars.usersWorkspaceRoot}/$username/books/ebooks" '[2,3,1]'
      add_desired_library "$username Comics" '1' "${vars.usersWorkspaceRoot}/$username/books/comics" '[1,4,3]'
      add_desired_library "$username Manga" '0' "${vars.usersWorkspaceRoot}/$username/books/manga" '[1,4]'
    done < "$desired_users_file"

    libraries_json="$(load_libraries_json)"
    users_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
      -H "$auth_header" \
      "$(api_url '/api/Users?includePending=false')")"

    changed=0
    scanned=0

    ensure_library() {
      local library_name="$1"
      local library_type="$2"
      local library_path="$3"
      local file_groups_json="$4"
      local current
      local create_payload
      local update_payload
      local library_id
      local current_shape
      local desired_shape

      current="$(
        printf '%s' "$libraries_json" \
          | ${pkgs.jq}/bin/jq -c --arg name "$library_name" '.[] | select(.name == $name)'
      )"

      create_payload="$(${pkgs.jq}/bin/jq -cn \
        --arg name "$library_name" \
        --arg path "$library_path" \
        --argjson type "$library_type" \
        --argjson file_groups "$file_groups_json" \
        '{
          id: 0,
          name: $name,
          type: $type,
          folders: [$path],
          folderWatching: true,
          includeInDashboard: true,
          includeInSearch: true,
          manageCollections: true,
          manageReadingLists: true,
          allowScrobbling: false,
          allowMetadataMatching: true,
          enableMetadata: true,
          removePrefixForSortName: false,
          inheritWebLinksFromFirstChapter: false,
          fileGroupTypes: $file_groups,
          excludePatterns: []
        }')"

      if [[ -z "$current" ]]; then
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "$auth_header" \
          -H 'Content-Type: application/json' \
          --data "$create_payload" \
          "$(api_url /api/Library/create)" >/dev/null
        changed=1
      else
        library_id="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -r '.id')"
        current_shape="$(
          printf '%s' "$current" \
            | ${pkgs.jq}/bin/jq -c '
              def decode_array:
                if . == null then []
                elif type == "string" then fromjson
                else .
                end;
              {
              name,
              type,
              folders: (.folders | decode_array | sort),
              folderWatching: (.folderWatching // true),
              includeInDashboard: (.includeInDashboard // true),
              includeInSearch: (.includeInSearch // true),
              manageCollections: (.manageCollections // true),
              manageReadingLists: (.manageReadingLists // true),
              allowScrobbling: (.allowScrobbling // false),
              allowMetadataMatching: (.allowMetadataMatching // true),
              enableMetadata: (.enableMetadata // true),
              removePrefixForSortName: (.removePrefixForSortName // false),
              inheritWebLinksFromFirstChapter: false,
              fileGroupTypes: (.libraryFileTypes | decode_array | sort),
              excludePatterns: (.excludePatterns | decode_array | sort)
            }'
        )"
        desired_shape="$(
          printf '%s' "$create_payload" \
            | ${pkgs.jq}/bin/jq -c '{
              name,
              type,
              folders: (.folders // [] | sort),
              folderWatching,
              includeInDashboard,
              includeInSearch,
              manageCollections,
              manageReadingLists,
              allowScrobbling,
              allowMetadataMatching,
              enableMetadata,
              removePrefixForSortName,
              inheritWebLinksFromFirstChapter,
              fileGroupTypes: (.fileGroupTypes // [] | sort),
              excludePatterns: (.excludePatterns // [] | sort)
            }'
        )"

        if [[ "$current_shape" != "$desired_shape" ]]; then
          update_payload="$(${pkgs.jq}/bin/jq -cn \
            --argjson id "$library_id" \
            --argjson payload "$create_payload" \
            '$payload | .id = $id')"

          ${pkgs.curl}/bin/curl --silent --show-error --fail \
            -X POST \
            -H "$auth_header" \
            -H 'Content-Type: application/json' \
            --data "$update_payload" \
            "$(api_url /api/Library/update)" >/dev/null
          changed=1
        fi
      fi

      libraries_json="$(load_libraries_json)"

      printf '%s' "$libraries_json" \
        | ${pkgs.jq}/bin/jq -r --arg name "$library_name" '.[] | select(.name == $name) | .id'
    }

    declare -A library_ids=()
    while IFS=$'\t' read -r library_name library_type library_path file_groups_json; do
      [[ -n "$library_name" && -n "$library_type" && -n "$library_path" ]] || continue
      library_id="$(ensure_library "$library_name" "$library_type" "$library_path" "$file_groups_json")"
      [[ -n "$library_id" ]] || {
        echo "Unable to converge Kavita library '$library_name'" >&2
        exit 1
      }
      library_ids["$library_name"]="$library_id"
    done < "$desired_libraries_file"

    managed_library_selection_json="$(
      ${pkgs.jq}/bin/jq -Rsc '
        split("\n")
        | map(select(length > 0))
      ' < "$managed_library_names_file" \
      | ${pkgs.jq}/bin/jq -c --argjson libs "$libraries_json" '
        def decode_array:
          if . == null then []
          elif type == "string" then fromjson
          else .
          end;
        [
          .[] as $name
          | $libs[]
          | select(.name == $name)
          | {
              id,
              name,
              type,
              libraryFileTypes: (.libraryFileTypes | decode_array),
              excludePatterns: (.excludePatterns | decode_array)
            }
        ]
      '
    )"

    update_user_access() {
      local username="$1"
      local mode="$2"
      local allowed_json="$3"
      local current
      local selected_json

      current="$(
        printf '%s' "$users_json" \
          | ${pkgs.jq}/bin/jq -c --arg username "$username" '.[] | select(.username == $username)'
      )"
      [[ -n "$current" ]] || return 0

      if [[ "$mode" == "admin" ]]; then
        selected_json="$managed_library_selection_json"
      else
        selected_json="$allowed_json"
      fi

      payload="$(${pkgs.jq}/bin/jq -cn \
        --arg username "$username" \
        --argjson selected "$selected_json" \
        '{ username: $username, selectedLibraries: $selected }')"

      ${pkgs.curl}/bin/curl --silent --show-error --fail \
        -X POST \
        -H "$auth_header" \
        -H 'Content-Type: application/json' \
        --data "$payload" \
        "$(api_url /api/Library/grant-access)" >/dev/null
    }

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue

      if ${pkgs.gnugrep}/bin/grep -Fxq "$username" "$admin_users_file"; then
        update_user_access "$username" admin '[]'
        continue
      fi

      allowed_json="$(
        ${pkgs.jq}/bin/jq -cn --argjson libs "$libraries_json" --arg username "$username" '
          def decode_array:
            if . == null then []
            elif type == "string" then fromjson
            else .
            end;
          [
            $libs[]
            | select(
                .name == "Shared Ebooks"
                or .name == "Shared Comics"
                or .name == "Shared Manga"
                or .name == ($username + " Ebooks")
                or .name == ($username + " Comics")
                or .name == ($username + " Manga")
              )
            | {
                id,
                name,
                type,
                libraryFileTypes: (.libraryFileTypes | decode_array),
                excludePatterns: (.excludePatterns | decode_array)
              }
          ]
        '
      )"
      update_user_access "$username" user "$allowed_json"
    done < "$desired_users_file"

    if [[ "$changed" -eq 1 ]]; then
      while IFS= read -r library_name; do
        [[ -n "$library_name" ]] || continue
        library_id="''${library_ids["$library_name"]:-}"
        [[ -n "$library_id" ]] || continue
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "$auth_header" \
          "$(api_url "/api/Library/scan?libraryId=$library_id&force=false")" >/dev/null
      done < "$managed_library_names_file"
      scanned=1
    fi

    if [[ "$scanned" -eq 1 ]]; then
      echo "Kavita libraries converged and scheduled for scan"
    fi
  '';
in
{
  systemd.services.kavita-library-sync-v1 = {
    description = "Synchronize Kavita managed personal and shared libraries";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "kavita.service"
      "kavita-oidc-bootstrap.service"
      "data-pool-layout.service"
      "fileshare-workspace-sync.service"
      "kanidm.service"
    ];
    after = [
      "kavita.service"
      "kavita-oidc-bootstrap.service"
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
      ${pkgs.coreutils}/bin/install -d -m 0750 ${managedDir}
      ${syncScript}
    '';
  };

  systemd.timers.kavita-library-sync-v1 = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* *:*:00";
      Persistent = true;
    };
  };
}
