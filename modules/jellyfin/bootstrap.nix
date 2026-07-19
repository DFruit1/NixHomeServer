{ config, lib, pkgs, vars, ... }:

let
  repoRoot = ../..;
  ageHeader = "-----BEGIN AGE ENCRYPTED FILE-----";
  mkSecretAssertions = secretNames:
    map
      (name:
        let
          secretPath = repoRoot + "/secrets/${name}.age";
          content = if builtins.pathExists secretPath then builtins.readFile secretPath else "";
        in
        {
          assertion =
            builtins.hasAttr name config.age.secrets
            && builtins.pathExists secretPath
            && content != ""
            && builtins.substring 0 (builtins.stringLength ageHeader) content == ageHeader;
          message = "Missing or invalid agenix secret '${name}'. Expected secrets/${name}.age to exist, be non-empty, and start with '${ageHeader}'. Stage cleartext at secrets/unencrypted/${name} if needed, then use nix run .#generate-secrets -- --identity /path/to/current/age.key.";
        })
      secretNames;
  loopback = vars.networking.loopbackIPv4;
  jellyfinPort = vars.networking.ports.jellyfin;
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  dataDir = "/var/lib/jellyfin";
  dataDbPath = "${dataDir}/data/jellyfin.db";
  managedDir = "${dataDir}/.nixos-managed";
  managedUsersFile = "${managedDir}/users.json";
  credentialStateFile = "${managedDir}/initial-credential-state.json";
  initialCredentialsDir = "${managedDir}/initial-credentials";
  showInitialCredential = pkgs.writeShellApplication {
    name = "jellyfin-initial-credential";
    runtimeInputs = [ pkgs.coreutils pkgs.findutils ];
    text = ''
      set -euo pipefail
      credential_dir=${lib.escapeShellArg initialCredentialsDir}
      if (( EUID != 0 )); then
        echo "Run this command through sudo because Jellyfin initial credentials are root-only." >&2
        exit 1
      fi
      username="''${1:-}"
      if [[ -z "$username" ]]; then
        echo "Available initial Jellyfin credentials:"
        find "$credential_dir" -mindepth 1 -maxdepth 1 -type f -printf '  %f\n' | sort
        echo "Use: sudo jellyfin-initial-credential USERNAME"
        exit 0
      fi
      case "$username" in
        ""|*/*|*..*|*[!A-Za-z0-9._-]*)
          echo "Invalid username." >&2
          exit 1
          ;;
      esac
      credential_file="$credential_dir/$username"
      if [[ ! -f "$credential_file" ]]; then
        echo "No initial credential is available for '$username'." >&2
        exit 1
      fi
      printf 'Jellyfin username: %s\nInitial password: ' "$username"
      cat "$credential_file"
      echo "Change this password after the first login, then securely delete the credential file if desired."
    '';
  };
  apiKeyFile = "${dataDir}/data/library-sync.api-key";
  apiKeyName = "nixos-jellyfin-library-sync-v1";
  knownProxiesXml = "<string>${vars.networking.loopbackProxyCidr}</string><string>${vars.networking.loopbackIPv6}/128</string>";
  jellyfinNetworkConfigPath = with pkgs; [
    coreutils
    perl
  ];
  jellyfinLibraryMonitorPath = with pkgs; [
    coreutils
    findutils
    perl
  ];
  sharedVideoLibraries = map
    (library: library // {
      name = "Shared ${library.label}";
      path = "${config.repo.jellyfin.paths.sharedVideosRoot}/${library.dir}";
      owner = null;
    })
    config.repo.jellyfin.libraries.shared;
  sharedMusicLibraries = map
    (library: library // {
      name = "Shared ${library.label}";
      path = "${config.repo.jellyfin.paths.sharedMusicRoot}/${library.dir}";
      owner = null;
    })
    config.repo.jellyfin.libraries.sharedMusic;
  sharedLibraries = sharedVideoLibraries ++ sharedMusicLibraries;
  sharedLibraryNames = map (library: library.name) sharedLibraries;
  sharedLibrariesJson = builtins.toJSON sharedLibraries;
  personalLibrariesJson = builtins.toJSON config.repo.jellyfin.libraries.personal;
  legacyVideoLibrariesJson = builtins.toJSON [
    {
      dir = "_Home";
      collectionType = "homevideos";
      label = "Home Videos";
    }
    {
      dir = "_YouTube";
      collectionType = "homevideos";
      label = "YouTube";
    }
  ];
  jellyfinAdminUsersJson = builtins.toJSON (vars.jellyfinAdminUsers or vars.kanidmAppAdminUsers);
  jellyfinAdminOwnerUser = vars.kanidmAdminUser;
  jellyfinLibraryBootstrapPath = with pkgs; [
    coreutils
    curl
    gnugrep
    jq
    kanidm_1_10
    openssl
    sqlite
  ];
in
{
  config = {
    environment.systemPackages = [ showInitialCredential ];

    assertions = (mkSecretAssertions [
      "kanidmAdminPass"
    ]) ++ [
      {
        assertion = builtins.length sharedLibraryNames == builtins.length (lib.unique sharedLibraryNames);
        message = "Jellyfin shared video and music library labels must be unique because both are displayed as 'Shared <label>'.";
      }
    ];

    systemd.services.jellyfin-network-config-v1 = {
      description = "Align Jellyfin reverse-proxy trust settings with local Caddy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "jellyfin.service" ];
      after = [ "jellyfin.service" ];
      path = jellyfinNetworkConfigPath;
      script = ''
        set -euo pipefail

        config_file="${dataDir}/config/network.xml"
        managed_dir="${managedDir}"
        marker_file="$managed_dir/jellyfin-network-config-v1.done"

        ${pkgs.coreutils}/bin/install -d -m 0755 "$managed_dir"

        if [[ -f "$marker_file" ]]; then
          echo "Jellyfin network config v1 already applied"
          exit 0
        fi

        for _ in $(seq 1 30); do
          [[ -f "$config_file" ]] && break
          sleep 1
        done
        [[ -f "$config_file" ]] || {
          echo "Jellyfin network configuration is not ready; retrying reconciliation." >&2
          exit 1
        }

        current="$(cat "$config_file")"
        updated="$(
          printf '%s' "$current" | ${pkgs.perl}/bin/perl -0pe '
            s#<KnownProxies(?:\s*/>|>.*?</KnownProxies>)#<KnownProxies>${knownProxiesXml}</KnownProxies>#s;
          '
        )"

        if [[ "$current" == "$updated" ]]; then
          echo "Jellyfin network config v1 already converged"
          touch "$marker_file"
          exit 0
        fi

        owner="$(stat -c '%u' "$config_file")"
        group="$(stat -c '%g' "$config_file")"
        mode="$(stat -c '%a' "$config_file")"
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        printf '%s' "$updated" >"$tmp"
        install -m "$mode" -o "$owner" -g "$group" "$tmp" "$config_file"
        echo "Jellyfin network config v1 updated KnownProxies"
        touch "$marker_file"
        /run/current-system/sw/bin/systemctl restart jellyfin.service
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.jellyfin-library-monitor-v1 = {
      description = "Tune Jellyfin's native realtime monitor for settled scans";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
      ];
      after = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
      ];
      path = jellyfinLibraryMonitorPath;
      script = ''
        set -euo pipefail

        config_file="${dataDir}/config/system.xml"
        library_root="${dataDir}/root/default"
        managed_dir="${managedDir}"
        marker_file="$managed_dir/jellyfin-library-monitor-v1.done"
        changed=0

        ${pkgs.coreutils}/bin/install -d -m 0755 "$managed_dir"

        for _ in $(seq 1 30); do
          [[ -f "$config_file" ]] && break
          sleep 1
        done
        [[ -f "$config_file" ]] || {
          echo "Jellyfin system configuration is not ready; retrying reconciliation." >&2
          exit 1
        }

        current="$(cat "$config_file")"
        updated="$(
          printf '%s' "$current" | ${pkgs.perl}/bin/perl -0pe '
            s#<LibraryMonitorDelay>.*?</LibraryMonitorDelay>#<LibraryMonitorDelay>20</LibraryMonitorDelay>#s;
            s#<LibraryUpdateDuration>.*?</LibraryUpdateDuration>#<LibraryUpdateDuration>30</LibraryUpdateDuration>#s;
          '
        )"

        if [[ "$current" == "$updated" ]]; then
          :
        else
          owner="$(stat -c '%u' "$config_file")"
          group="$(stat -c '%g' "$config_file")"
          mode="$(stat -c '%a' "$config_file")"
          tmp="$(mktemp)"
          trap 'rm -f "$tmp"' EXIT
          printf '%s' "$updated" >"$tmp"
          install -m "$mode" -o "$owner" -g "$group" "$tmp" "$config_file"
          changed=1
        fi

        if [[ -d "$library_root" ]]; then
          while IFS= read -r -d "" options_file; do
            current="$(cat "$options_file")"
            updated="$(
              printf '%s' "$current" | ${pkgs.perl}/bin/perl -0pe '
                if (!s#<EnableRealtimeMonitor>.*?</EnableRealtimeMonitor>#<EnableRealtimeMonitor>true</EnableRealtimeMonitor>#s) {
                  s#(<Enabled>.*?</Enabled>)#$1\n  <EnableRealtimeMonitor>true</EnableRealtimeMonitor>#s;
                }
              '
            )"

            [[ "$current" != "$updated" ]] || continue

            owner="$(stat -c '%u' "$options_file")"
            group="$(stat -c '%g' "$options_file")"
            mode="$(stat -c '%a' "$options_file")"
            tmp="$(mktemp)"
            printf '%s' "$updated" >"$tmp"
            install -m "$mode" -o "$owner" -g "$group" "$tmp" "$options_file"
            rm -f "$tmp"
            changed=1
          done < <(find "$library_root" -mindepth 2 -maxdepth 2 -name options.xml -print0)
        fi

        touch "$marker_file"
        if (( changed == 1 )); then
          /run/current-system/sw/bin/systemctl restart jellyfin.service
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.jellyfin-library-bootstrap-v1 = {
      description = "Converge declarative Jellyfin libraries and managed user policies";
      wantedBy = [ "multi-user.target" ];
      after = [
        "jellyfin.service"
        "media-folder-layout-v2.service"
        "jellyfin-storage-layout-v1.service"
        "fileshare-user-root-sync.service"
        "kanidm.service"
      ];
      requires = [ "data-pool-layout.service" ];
      wants = [
        "jellyfin.service"
        "media-folder-layout-v2.service"
        "jellyfin-storage-layout-v1.service"
        "fileshare-user-root-sync.service"
        "kanidm.service"
        "data-pool-layout.service"
      ];
      path = jellyfinLibraryBootstrapPath;
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg dataDbPath}
        managed_dir=${lib.escapeShellArg managedDir}
        managed_users_file=${lib.escapeShellArg managedUsersFile}
        credential_state_file=${lib.escapeShellArg credentialStateFile}
        initial_credentials_dir=${lib.escapeShellArg initialCredentialsDir}
        api_key_file=${lib.escapeShellArg apiKeyFile}
        api_key_name=${lib.escapeShellArg apiKeyName}
        jellyfin_admin_owner_user=${lib.escapeShellArg jellyfinAdminOwnerUser}
        base_url="http://${loopback}:${toString jellyfinPort}"
        api_keys_table=""
        api_key=""
        changed=0
        shared_libraries_json=${lib.escapeShellArg sharedLibrariesJson}
        personal_libraries_json=${lib.escapeShellArg personalLibrariesJson}
        legacy_video_libraries_json=${lib.escapeShellArg legacyVideoLibrariesJson}
        jellyfin_admin_users_json=${lib.escapeShellArg jellyfinAdminUsersJson}

        for _ in $(seq 1 60); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || {
          echo "Jellyfin database not found at $db; retrying library bootstrap." >&2
          exit 1
        }

        ready=0
        for _ in $(seq 1 60); do
          if curl \
            --silent \
            --show-error \
            --fail \
            --max-time 5 \
            "$base_url/System/Info/Public" \
            >/dev/null; then
            ready=1
            break
          fi
          sleep 1
        done
        (( ready == 1 )) || {
          echo "Jellyfin HTTP endpoint is not ready yet; retrying library bootstrap." >&2
          exit 1
        }

        if sqlite3 -readonly "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'ApiKeys' LIMIT 1;" | grep -qx '1'; then
          api_keys_table='ApiKeys'
        elif sqlite3 -readonly "$db" "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'jellyfin.ApiKeys' LIMIT 1;" | grep -qx '1'; then
          api_keys_table='"jellyfin.ApiKeys"'
        else
          echo "Failed to find the Jellyfin API keys table in $db" >&2
          exit 1
        fi

        export HOME="$(mktemp -d)"
        trap 'rm -rf "$HOME"' EXIT
        KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
        export KANIDM_PASSWORD
        kanidm login -H ${kanidmCliUrl} -D idm_admin >/dev/null

        snapshot_group_members_json() {
          local group_name="$1"
          local group_json members_json

          if ! group_json="$(
            kanidm group get \
              "$group_name" \
              -H ${kanidmCliUrl} \
              -D idm_admin \
              -o json
          )"; then
            echo "Unable to read Kanidm group '$group_name'; refusing to reconcile Jellyfin" >&2
            return 1
          fi
          if ! members_json="$(
            jq -cer '
              if ((.attrs.member // []) | type) != "array" then
                error("Kanidm group member attribute is not an array")
              else
                [ .attrs.member[]? | strings | split("@")[0] | select(length > 0) ] | unique
              end
            ' <<<"$group_json"
          )"; then
            echo "Kanidm returned an invalid membership document for '$group_name'; refusing to reconcile Jellyfin" >&2
            return 1
          fi

          printf '%s\n' "$members_json"
        }

        # Identity is authoritative for destructive library and policy changes.
        # Stage every required snapshot before provisioning an API key or
        # mutating any Jellyfin library/user state.
        if ! jellyfin_members_json="$(snapshot_group_members_json jellyfin-users)"; then
          exit 1
        fi
        if ! shared_members_json="$(snapshot_group_members_json ${lib.escapeShellArg sharedAccessGroup})"; then
          exit 1
        fi
        if ! app_admin_members_json="$(snapshot_group_members_json app-admin)"; then
          exit 1
        fi
        jellyfin_admin_members_json="$(
          jq -n \
            --argjson appAdmins "$app_admin_members_json" \
            --argjson allowed "$jellyfin_admin_users_json" \
            '$appAdmins | map(select($allowed | index(.) != null))'
        )"

        expected_libraries="$(
          jq -n \
            --arg usersRoot ${lib.escapeShellArg vars.usersRoot} \
            --argjson shared "$shared_libraries_json" \
            --argjson personal "$personal_libraries_json" \
            --argjson users "$jellyfin_members_json" \
            '$shared + [ $users[] as $user | $personal[] | . + {
              name: ($user + " " + .label),
              path: ($usersRoot + "/" + $user + "/_Videos/" + .dir),
              owner: $user
            } ]'
        )"

        legacy_libraries="$(
          jq -n \
            --arg usersRoot ${lib.escapeShellArg vars.usersRoot} \
            --arg sharedVideosRoot ${lib.escapeShellArg config.repo.jellyfin.paths.sharedVideosRoot} \
            --argjson legacy "$legacy_video_libraries_json" \
            --argjson users "$jellyfin_members_json" \
            '[ $legacy[] | . + {
              name: ("Shared " + .label),
              path: ($sharedVideosRoot + "/" + .dir),
              owner: null
            } ]
            + [ $users[] as $user | $legacy[] | . + {
              name: ($user + " " + .label),
              path: ($usersRoot + "/" + $user + "/_Videos/" + .dir),
              owner: $user
            } ]'
        )"

        install -d -m 0750 -o jellyfin -g jellyfin "$managed_dir"
        install -d -m 0700 -o root -g root "$initial_credentials_dir"

        api_key="$(sqlite3 -readonly -cmd '.timeout 5000' "$db" "
          SELECT AccessToken
          FROM $api_keys_table
          WHERE Name = '$api_key_name'
          ORDER BY Id DESC
          LIMIT 1;
        " 2>/dev/null || true)"

        if [[ -z "$api_key" ]]; then
          api_key="$(tr -d '-' </proc/sys/kernel/random/uuid)"
          sqlite3 -cmd '.timeout 5000' "$db" "
            INSERT INTO $api_keys_table (DateCreated, DateLastActivity, Name, AccessToken)
            SELECT datetime('now'), datetime('now'), '$api_key_name', '$api_key'
            WHERE NOT EXISTS (
              SELECT 1
              FROM $api_keys_table
              WHERE Name = '$api_key_name'
            );
          "
          api_key="$(sqlite3 -readonly -cmd '.timeout 5000' "$db" "
            SELECT AccessToken
            FROM $api_keys_table
            WHERE Name = '$api_key_name'
            ORDER BY Id DESC
            LIMIT 1;
          ")"
        fi

        [[ -n "$api_key" ]] || {
          echo "Failed to provision the Jellyfin library bootstrap API key" >&2
          exit 1
        }

        printf '%s\n' "$api_key" >"$api_key_file"
        chown jellyfin:jellyfin "$api_key_file"
        chmod 0600 "$api_key_file"

        curl_jellyfin() {
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 60 \
            -H "X-Emby-Token: $api_key" \
            "$@"
        }

        refresh_virtual_folders() {
          virtual_folders="$(
            curl_jellyfin "$base_url/Library/VirtualFolders"
          )"
        }

        refresh_users() {
          jellyfin_users="$(
            curl_jellyfin "$base_url/Users"
          )"
        }

        post_policy() {
          local user_id="$1"
          local policy_json="$2"

          curl_jellyfin \
            -X POST \
            -H "Content-Type: application/json" \
            --data-binary "$policy_json" \
            "$base_url/Users/$user_id/Policy" \
            >/dev/null
        }

        set_initial_password() {
          local user_id="$1"
          local password="$2"

          # Reset first so this also recovers users created by the former bootstrap,
          # whose randomly generated password was never handed to the operator.
          jq -n '{ResetPassword: true}' \
            | curl_jellyfin \
              -X POST \
              -H "Content-Type: application/json" \
              --data-binary @- \
              "$base_url/Users/$user_id/Password" \
              >/dev/null
          jq -n --arg password "$password" \
            '{CurrentPw: "", NewPw: $password, ResetPassword: false}' \
            | curl_jellyfin \
              -X POST \
              -H "Content-Type: application/json" \
              --data-binary @- \
              "$base_url/Users/$user_id/Password" \
              >/dev/null
        }

        provision_initial_credential() {
          local username="$1"
          local user_id="$2"
          local password="''${3:-}"
          local credential_file temporary

          if jq -e --arg username "$username" '.initializedUsers | index($username) != null' \
            >/dev/null <<<"$credential_state_json"; then
            return 0
          fi
          case "$username" in
            ""|*/*|*..*|*[!A-Za-z0-9._-]*)
              echo "Refusing unsafe Jellyfin username '$username'" >&2
              exit 1
              ;;
          esac

          if [[ -z "$password" ]]; then
            password="$(openssl rand -base64 36 | tr -d '\n')"
            set_initial_password "$user_id" "$password"
          fi

          credential_file="$initial_credentials_dir/$username"
          temporary="$(mktemp)"
          printf '%s\n' "$password" >"$temporary"
          install -m 0600 -o root -g root "$temporary" "$credential_file"
          rm -f "$temporary"
          credential_state_json="$(
            jq --arg username "$username" \
              '.initializedUsers = ((.initializedUsers + [$username]) | unique)' \
              <<<"$credential_state_json"
          )"
          echo "Initial Jellyfin credential for '$username' is available to root at $credential_file"
        }

        library_matches() {
          local name="$1"
          local collection_type="$2"
          local path="$3"

          jq -e \
            --arg name "$name" \
            --arg collectionType "$collection_type" \
            --arg path "$path" \
            'any(.[]; .Name == $name and .CollectionType == $collectionType and ((.Locations // []) | index($path) != null))' \
            >/dev/null <<<"$virtual_folders"
        }

        library_exists() {
          local name="$1"

          jq -e --arg name "$name" 'any(.[]; .Name == $name)' >/dev/null <<<"$virtual_folders"
        }

        library_item_id() {
          local name="$1"
          local path="$2"

          jq -r \
            --arg name "$name" \
            --arg path "$path" \
            '.[] | select(.Name == $name and ((.Locations // []) | index($path) != null)) | .ItemId // empty' \
            <<<"$virtual_folders" \
            | head -n 1
        }

        delete_virtual_folder() {
          local name="$1"
          local path="$2"

          if ! jq -e \
            --arg name "$name" \
            --arg path "$path" \
            'any(.[]; .Name == $name and ((.Locations // []) | index($path) != null))' \
            >/dev/null <<<"$virtual_folders"; then
            return 0
          fi

          echo "Removing legacy managed Jellyfin library '$name' at $path"
          curl_jellyfin \
            -X DELETE \
            -G \
            --data-urlencode "name=$name" \
            --data-urlencode "refreshLibrary=false" \
            "$base_url/Library/VirtualFolders" \
            >/dev/null
          changed=1
          refresh_virtual_folders
        }

        refresh_virtual_folders

        while IFS=$'\t' read -r name path; do
          [[ -n "$name" && -n "$path" ]] || continue
          delete_virtual_folder "$name" "$path"
        done < <(
          jq -r '.[] | [.name, .path] | @tsv' <<<"$legacy_libraries"
        )

        while IFS=$'\t' read -r name collection_type path; do
          [[ -n "$name" ]] || continue
          if library_exists "$name"; then
            if library_matches "$name" "$collection_type" "$path"; then
              echo "Jellyfin library already converged: $name"
              continue
            fi

            echo "Jellyfin library '$name' already exists but does not match managed path '$path' and type '$collection_type'." >&2
            echo "Refusing to rewrite a user-managed Jellyfin library." >&2
            exit 1
          fi

          echo "Creating Jellyfin library '$name' at $path"
          curl_jellyfin \
            -X POST \
            -G \
            --data-urlencode "name=$name" \
            --data-urlencode "collectionType=$collection_type" \
            --data-urlencode "paths=$path" \
            --data-urlencode "refreshLibrary=false" \
            "$base_url/Library/VirtualFolders" \
            >/dev/null
          changed=1
          refresh_virtual_folders
        done < <(
          jq -r '.[] | [.name, .collectionType, .path] | @tsv' <<<"$expected_libraries"
        )

        refresh_virtual_folders
        refresh_users

        if [[ -f "$managed_users_file" ]]; then
          managed_users_json="$(jq 'map(select((.name // "") != "" and (.id // "") != ""))' "$managed_users_file")"
        else
          managed_users_json='[]'
        fi
        if [[ -f "$credential_state_file" ]]; then
          credential_state_json="$(jq -c '
            if (.schemaVersion == 1 and (.initializedUsers | type == "array"))
            then .
            else error("invalid Jellyfin initial credential state")
            end
          ' "$credential_state_file")"
        else
          credential_state_json='{"schemaVersion":1,"initializedUsers":[]}'
        fi

        while IFS= read -r username; do
          [[ -n "$username" ]] || continue

          user_id="$(jq -r --arg name "$username" '.[] | select(.Name == $name) | .Id // empty' <<<"$jellyfin_users" | head -n 1)"
          if [[ -z "$user_id" ]]; then
            password="$(openssl rand -base64 48)"
            echo "Creating managed Jellyfin user '$username'"
            created_user="$(
              jq -n --arg name "$username" --arg password "$password" '{Name: $name, Password: $password}' \
                | curl_jellyfin \
                  -X POST \
                  -H "Content-Type: application/json" \
                  --data-binary @- \
                  "$base_url/Users/New"
            )"
            user_id="$(jq -r '.Id // empty' <<<"$created_user")"
            [[ -n "$user_id" ]] || {
              echo "Jellyfin did not return an Id for newly created user '$username'." >&2
              exit 1
            }
            initial_policy="$(
              jq -c '
                (.Policy // {})
                | .IsAdministrator = false
                | .IsHidden = true
                | .IsDisabled = true
                | .EnableAllFolders = false
                | .EnabledFolders = []
              ' <<<"$created_user"
            )"
            if [[ "$username" == "$jellyfin_admin_owner_user" ]]; then
              initial_policy="$(
                jq -c '
                  .IsAdministrator = true
                  | .IsHidden = false
                  | .IsDisabled = false
                  | .EnableAllFolders = false
                  | .EnableMediaPlayback = true
                ' <<<"$initial_policy"
              )"
            fi
            post_policy "$user_id" "$initial_policy"
            provision_initial_credential "$username" "$user_id" "$password"
            managed_users_json="$(
              jq --arg name "$username" --arg id "$user_id" '
                (. + [{name: $name, id: $id}]) | unique_by(.name)
              ' <<<"$managed_users_json"
            )"
            refresh_users
          fi

          # Recover legacy managed accounts once. A root-only marker prevents
          # subsequent reconciliations from overwriting a user-chosen password.
          provision_initial_credential "$username" "$user_id"

          is_admin=false
          if jq -e --arg name "$username" 'index($name) != null' >/dev/null <<<"$jellyfin_admin_members_json"; then
            is_admin=true
          fi

          current_policy="$(jq -c --arg id "$user_id" '.[] | select(.Id == $id) | .Policy // {}' <<<"$jellyfin_users" | head -n 1)"
          [[ -n "$current_policy" ]] || current_policy='{}'
          current_is_admin="$(jq -r '.IsAdministrator // false' <<<"$current_policy")"

          has_shared_access=false
          if jq -e --arg name "$username" 'index($name) != null' >/dev/null <<<"$shared_members_json"; then
            has_shared_access=true
          fi
          if [[ "$has_shared_access" != "true" ]]; then
            is_admin=false
          fi
          if [[ "$username" == "$jellyfin_admin_owner_user" ]]; then
            is_admin=true
          fi

          if [[ "$current_is_admin" == "true" && "$is_admin" != "true" ]]; then
            current_admin_count="$(jq 'map(select((.Policy // {}).IsAdministrator == true)) | length' <<<"$jellyfin_users")"
            if [[ "$current_admin_count" == "1" ]]; then
              echo "Preserving Jellyfin admin status for '$username' to avoid removing the only administrative account."
              is_admin=true
            fi
          fi
          expected_count="$(
            jq --arg name "$username" --argjson hasSharedAccess "$has_shared_access" \
              '[.[] | select((.owner == $name) or (.owner == null and $hasSharedAccess))] | length' <<<"$expected_libraries"
          )"
          folder_ids="$(
            jq -n \
              --arg name "$username" \
              --argjson hasSharedAccess "$has_shared_access" \
              --argjson expected "$expected_libraries" \
              --argjson folders "$virtual_folders" \
              '[ $expected[] | select((.owner == $name) or (.owner == null and $hasSharedAccess)) as $spec |
                ($folders[] | select(.Name == $spec.name and ((.Locations // []) | index($spec.path) != null)) | .ItemId // empty)
              ] | unique'
          )"
          actual_count="$(jq 'length' <<<"$folder_ids")"
          if [[ "$actual_count" != "$expected_count" ]]; then
            echo "Expected $expected_count Jellyfin folder IDs for '$username' but found $actual_count." >&2
            exit 1
          fi

          desired_policy="$(
            jq -c --argjson isAdmin "$is_admin" --argjson folderIds "$folder_ids" '
              .IsAdministrator = $isAdmin
              | .IsHidden = false
              | .IsDisabled = false
              | .EnableAllFolders = false
              | .EnabledFolders = $folderIds
              | .EnableMediaPlayback = true
            ' <<<"$current_policy"
          )"
          if [[ "$username" == "$jellyfin_admin_owner_user" ]]; then
            desired_policy="$(
              jq -c '
                .IsAdministrator = true
                | .IsHidden = false
                | .IsDisabled = false
                | .EnableAllFolders = false
                | .EnableMediaPlayback = true
              ' <<<"$desired_policy"
            )"
          fi

          if [[ "$current_policy" != "$desired_policy" ]]; then
            echo "Updating Jellyfin policy for '$username'"
            post_policy "$user_id" "$desired_policy"
          fi
        done < <(jq -r '.[]' <<<"$jellyfin_members_json")

        while IFS=$'\t' read -r username user_id; do
          [[ -n "$username" && -n "$user_id" ]] || continue
          if [[ "$username" == "$jellyfin_admin_owner_user" ]]; then
            echo "Skipping policy reset for dedicated Jellyfin admin '$username'"
            continue
          fi
          if jq -e --arg name "$username" 'index($name) != null' >/dev/null <<<"$jellyfin_members_json"; then
            continue
          fi
          if ! jq -e --arg id "$user_id" 'any(.[]; .Id == $id)' >/dev/null <<<"$jellyfin_users"; then
            continue
          fi

          current_policy="$(jq -c --arg id "$user_id" '.[] | select(.Id == $id) | .Policy // {}' <<<"$jellyfin_users" | head -n 1)"
          [[ -n "$current_policy" ]] || current_policy='{}'
          current_is_admin="$(jq -r '.IsAdministrator // false' <<<"$current_policy")"
          desired_policy="$(
            jq -c '
              .IsAdministrator = false
              | .IsDisabled = true
              | .EnableAllFolders = false
              | .EnabledFolders = []
            ' <<<"$current_policy"
          )"
          if [[ "$current_policy" != "$desired_policy" ]]; then
            if [[ "$current_is_admin" == "true" ]]; then
              current_admin_count="$(jq 'map(select((.Policy // {}).IsAdministrator == true)) | length' <<<"$jellyfin_users")"
              if [[ "$current_admin_count" == "1" ]]; then
                echo "Skipping admin removal for '$username' because it would leave Jellyfin without any administrative users."
                continue
              fi
            fi
            echo "Disabling managed Jellyfin user '$username' removed from jellyfin-users"
            post_policy "$user_id" "$desired_policy"
          fi
        done < <(jq -r '.[] | [.name, .id] | @tsv' <<<"$managed_users_json")

        tmp_users="$(mktemp)"
        printf '%s\n' "$managed_users_json" >"$tmp_users"
        install -m 0600 -o jellyfin -g jellyfin "$tmp_users" "$managed_users_file"
        rm -f "$tmp_users"
        tmp_credential_state="$(mktemp)"
        printf '%s\n' "$credential_state_json" >"$tmp_credential_state"
        install -m 0600 -o root -g root "$tmp_credential_state" "$credential_state_file"
        rm -f "$tmp_credential_state"

        if (( changed == 1 )); then
          /run/current-system/sw/bin/systemctl start --no-block jellyfin-library-sync.service
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      unitConfig = lib.mkMerge [
        { RequiresMountsFor = [ vars.dataRoot ]; }
        (lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        })
      ];
    };
  };
}
