{ config, lib, pkgs, pkgsUnstable, vars, ... }:

let
  stateDir = vars.filebrowserStateDir;
  configFile = "${stateDir}/config.yaml";
  managedDir = "${stateDir}/.nixos-managed";
  accessSyncStamp = "${managedDir}/last-sync.json";
  localAdminUsername = "local-admin";
  filebrowserPackage = pkgsUnstable."filebrowser-quantum";
  customCssFile = pkgs.writeText "filebrowser-quantum-custom.css" ''
    #sidebar .credits {
      display: none !important;
    }
  '';
  yamlFormat = pkgs.formats.yaml { };
  configTemplate = yamlFormat.generate "filebrowser-quantum-config-template.yaml" {
    server = {
      listen = "127.0.0.1";
      port = vars.filebrowserPort;
      baseURL = "/";
      database = "${stateDir}/database.db";
      cacheDir = "${stateDir}/cache";
      externalUrl = "https://${vars.filebrowserDomain}";
      internalUrl = "http://127.0.0.1:${toString vars.filebrowserPort}";
      disableUpdateCheck = true;
      filesystem = {
        createFilePermission = "660";
        createDirectoryPermission = "2770";
      };
      logging = [
        {
          levels = "info|warning|error";
          apiLevels = "info|warning|error";
          output = "stdout";
          noColors = true;
          utc = false;
        }
      ];
      sources = [
        {
          path = vars.usersRoot;
          name = "Personal";
          config = {
            defaultEnabled = true;
            createUserDir = true;
            defaultUserScope = "/";
          };
        }
        {
          path = vars.sharedRoot;
          name = "Shared";
          config = {
            defaultEnabled = false;
            defaultUserScope = "/";
            denyByDefault = true;
          };
        }
      ];
    };
    frontend = {
      name = "Files";
      disableDefaultLinks = true;
      externalLinks = [ ];
      styling.customCSS = customCssFile;
      oidcLoginButtonText = "Login with Kanidm";
    };
    auth = {
      key = "@JWT_KEY@";
      adminUsername = localAdminUsername;
      adminPassword = "@ADMIN_PASSWORD@";
      methods = {
        password = {
          # Keep the password method available for the local admin API user
          # that converges scopes and permissions. End-user browser login still
          # flows through OIDC.
          enabled = true;
          signup = false;
        };
        oidc = {
          enabled = true;
          issuerUrl = vars.kanidmIssuer "filebrowser-quantum-web";
          clientId = "filebrowser-quantum-web";
          clientSecret = "@OIDC_CLIENT_SECRET@";
          createUser = true;
          scopes = "openid email profile groups_name";
          userIdentifier = "preferred_username";
          groupsClaim = "groups";
        };
      };
    };
    userDefaults = {
      permissions = {
        admin = false;
        api = false;
        download = true;
        share = true;
        create = true;
        modify = true;
        delete = true;
        realtime = false;
      };
    };
  };
in
{
  users.groups.filebrowser-quantum = { };
  users.users.filebrowser-quantum = {
    isSystemUser = true;
    group = "filebrowser-quantum";
    home = stateDir;
    createHome = false;
    extraGroups = [
      "users"
      "audiobookshelf-media"
      "kavita-media"
      "jellyfin-media"
      "kiwix"
    ];
  };

  systemd.tmpfiles.rules = [
    "d ${managedDir} 0750 filebrowser-quantum filebrowser-quantum -"
  ];

  systemd.services.filebrowser-quantum = {
    description = "FileBrowser Quantum";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "data-pool-layout.service"
      "fileshare-user-root-sync.service"
      "network-online.target"
    ];
    after = [
      "data-pool-layout.service"
      "fileshare-user-root-sync.service"
      "network-online.target"
    ];
    path = with pkgs; [
      coreutils
      replace-secret
    ];
    preStart = ''
      install -d -m 0750 -o filebrowser-quantum -g filebrowser-quantum '${managedDir}'
      cp ${configTemplate} '${configFile}'
      chown filebrowser-quantum:filebrowser-quantum '${configFile}'
      chmod 0400 '${configFile}'

      ${pkgs.replace-secret}/bin/replace-secret \
        '@OIDC_CLIENT_SECRET@' \
        ${config.age.secrets.filebrowserQuantumClientSecret.path} \
        '${configFile}'
      ${pkgs.replace-secret}/bin/replace-secret \
        '@ADMIN_PASSWORD@' \
        ${config.age.secrets.filebrowserQuantumAdminPassword.path} \
        '${configFile}'
      ${pkgs.replace-secret}/bin/replace-secret \
        '@JWT_KEY@' \
        ${config.age.secrets.filebrowserQuantumJwtSecret.path} \
        '${configFile}'
    '';
    serviceConfig = {
      Type = "simple";
      User = "filebrowser-quantum";
      Group = "filebrowser-quantum";
      PermissionsStartOnly = true;
      WorkingDirectory = stateDir;
      ExecStart = lib.getExe filebrowserPackage;
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "filebrowser-quantum";
      StateDirectoryMode = "0750";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectProc = "invisible";
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      RemoveIPC = true;
      RestrictSUIDSGID = true;
      RestrictRealtime = true;
      ReadWritePaths = [
        stateDir
        vars.usersRoot
        vars.sharedRoot
        vars.kiwixLibraryRoot
      ];
      UMask = "0007";
    };
  };

  systemd.services.filebrowser-quantum-access-sync-v1 = {
    description = "Converge FileBrowser Quantum access rules and user scopes";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "filebrowser-quantum.service"
      "fileshare-user-root-sync.service"
      "data-pool-layout.service"
      "kanidm.service"
    ];
    after = [
      "filebrowser-quantum.service"
      "fileshare-user-root-sync.service"
      "data-pool-layout.service"
      "kanidm.service"
    ];
    path = with pkgs; [
      curl
      coreutils
      gnused
      jq
    ];
    script = ''
      set -euo pipefail

      api_base="http://127.0.0.1:${toString vars.filebrowserPort}"
      admin_username=${lib.escapeShellArg localAdminUsername}
      admin_password="$(< ${config.age.secrets.filebrowserQuantumAdminPassword.path})"
      admin_password_header="$(jq -nr --arg value "$admin_password" '$value|@uri')"
      token=""

      urlencode() {
        jq -nr --arg value "$1" '$value|@uri'
      }

      api_get() {
        local path="$1"
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -H "Authorization: Bearer $token" \
          "$api_base$path"
      }

      api_post() {
        local path="$1"
        local body="$2"
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --data "$body" \
          "$api_base$path"
      }

      api_put() {
        local path="$1"
        local body="$2"
        ${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X PUT \
          -H "Authorization: Bearer $token" \
          -H "X-Password: $admin_password_header" \
          -H 'Content-Type: application/json' \
          --data "$body" \
          "$api_base$path"
      }

      wait_for_health() {
        local health_json=""

        for _ in $(seq 1 60); do
          if health_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
            "$api_base/health" 2>/dev/null)"; then
            if jq -e '.message == "ok"' >/dev/null <<<"$health_json"; then
              return 0
            fi
          fi
          sleep 1
        done

        echo "FileBrowser Quantum health endpoint did not become ready" >&2
        exit 1
      }

      login() {
        local response

        response="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          -X POST \
          -H "X-Password: $admin_password" \
          "$api_base/api/auth/login?username=$(urlencode "$admin_username")")"

        token="$(jq -er 'if type == "string" then . else (.token // .jwt // .access_token // empty) end' <<<"$response" 2>/dev/null || true)"
        if [[ -z "$token" ]]; then
          token="$(printf '%s' "$response" | tr -d '\r\n')"
        fi
        [[ -n "$token" ]] || {
          echo "Failed to obtain FileBrowser Quantum API token" >&2
          exit 1
        }
      }

      ensure_group_membership() {
        local group_name="$1"
        local groups_json

        groups_json="$(api_get "/api/access/groups?user=$(urlencode "$admin_username")" | jq -c '.groups // []')"
        if ! jq -e --arg group_name "$group_name" 'index($group_name) != null' >/dev/null <<<"$groups_json"; then
          api_post "/api/access/group?group=$(urlencode "$group_name")&user=$(urlencode "$admin_username")" '{}' >/dev/null
        fi
      }

      ensure_allow_group() {
        local source_name="$1"
        local index_path="$2"
        local group_name="$3"
        ensure_access_rule "$source_name" "$index_path" true group "$group_name"
      }

      ensure_deny_user() {
        local source_name="$1"
        local index_path="$2"
        local username="$3"
        ensure_access_rule "$source_name" "$index_path" false user "$username"
      }

      ensure_access_rule() {
        local source_name="$1"
        local index_path="$2"
        local allow="$3"
        local rule_category="$4"
        local value="$5"
        local current_rule response body status

        current_rule="$(api_get "/api/access?source=$(urlencode "$source_name")&path=$(urlencode "$index_path")")"
        if ! jq -e \
          --arg allow "$allow" \
          --arg rule_category "$rule_category" \
          --arg value "$value" '
            if $rule_category == "group" then
              if $allow == "true" then
                .allow.groups // [] | index($value) != null
              else
                .deny.groups // [] | index($value) != null
              end
            else
              if $allow == "true" then
                .allow.users // [] | index($value) != null
              else
                .deny.users // [] | index($value) != null
              end
            end
          ' >/dev/null <<<"$current_rule"; then
          response="$(${pkgs.curl}/bin/curl --silent --show-error \
            -X POST \
            -H "Authorization: Bearer $token" \
            -H 'Content-Type: application/json' \
            --data "$(jq -cn \
              --argjson allow "$allow" \
              --arg rule_category "$rule_category" \
              --arg value "$value" \
              '{allow:$allow, ruleCategory:$rule_category, value:$value}')" \
            --write-out $'\n%{http_code}' \
            "$api_base/api/access?source=$(urlencode "$source_name")&path=$(urlencode "$index_path")")"
          status="''${response##*$'\n'}"
          body="''${response%$'\n'*}"

          if [[ "$status" == "500" ]] && grep -Fq "already exists" <<<"$body"; then
            return 0
          fi

          [[ "$status" == "200" ]] || {
            printf '%s\n' "$body" >&2
            return 1
          }
        fi
      }

      sync_user() {
        local user_json="$1"
        local username login_method groups_json desired_scopes desired_permissions desired_sidebar_links updated_user

        username="$(jq -r '.username' <<<"$user_json")"
        login_method="$(jq -r '.loginMethod' <<<"$user_json")"

        if [[ "$username" == "$admin_username" ]]; then
          desired_scopes='[
            {"name":"Personal","scope":"/"},
            {"name":"Shared","scope":"/"}
          ]'
          desired_permissions='{"api":true,"admin":true,"modify":true,"share":true,"realtime":false,"delete":true,"create":true,"download":true}'
          desired_sidebar_links='[]'
        else
          [[ "$login_method" == "oidc" ]] || return 0
          groups_json="$(api_get "/api/access/groups?user=$(urlencode "$username")" | jq -c '.groups // []')"

          desired_scopes="$(jq -cn \
            --arg username "$username" \
            --argjson groups "$groups_json" '
              def has_group($group_name): ($groups | index($group_name)) != null;
              [
                if has_group("user-files") then
                  {name:"Personal", scope:("/" + $username)}
                else empty end,
                if has_group("shared-files-read-write-access") then
                  {name:"Shared", scope:"/"}
                else empty end
              ]')"

          # FileBrowser Quantum exposes per-user global permissions plus source access
          # rules rather than per-source permissions. The explicit
          # shared-files-read-write-access group therefore gates all shared-files
          # visibility in this single-instance model, and members who also hold
          # user-files will have write-capable permissions across the sources they
          # can access.
          desired_permissions="$(jq -cn --argjson groups "$groups_json" '
            def has_group($group_name): ($groups | index($group_name)) != null;
            {
              api: (has_group("user-files") or has_group("shared-files-read-write-access")),
              admin: false,
              modify: (has_group("user-files") or has_group("shared-files-read-write-access")),
              share: (has_group("user-files") or has_group("shared-files-read-write-access")),
              realtime: false,
              delete: (has_group("user-files") or has_group("shared-files-read-write-access")),
              create: (has_group("user-files") or has_group("shared-files-read-write-access")),
              download: true
            }')"

          desired_sidebar_links="$(jq -cn --argjson groups "$groups_json" '
            def has_group($group_name): ($groups | index($group_name)) != null;
            [
              if has_group("user-files") then
                {name:"Personal", category:"source", target:"/", icon:"", sourceName:"Personal"},
                {name:"Files", category:"source", target:"/files/", icon:"file_present", sourceName:"Personal"},
                {name:"Uploads", category:"source", target:"/uploads/", icon:"cloud_upload", sourceName:"Personal"}
              else empty end,
              if has_group("user-files") and has_group("shared-files-read-write-access") then
                {name:"", category:"divider", target:"#", icon:""}
              else empty end,
              if has_group("shared-files-read-write-access") then
                {name:"Shared", category:"source", target:"/", icon:"", sourceName:"Shared"}
              else empty end
            ]')"

          if jq -e 'index("user-files") != null' >/dev/null <<<"$groups_json"; then
            ensure_deny_user "Personal" "/$username/documents" "$username"
            ensure_deny_user "Personal" "/$username/photos" "$username"
          fi
        fi

        updated_user="$(jq -c \
          --argjson scopes "$desired_scopes" \
          --argjson permissions "$desired_permissions" \
          --argjson sidebar_links "$desired_sidebar_links" \
          '.scopes = $scopes | .permissions = $permissions | .sidebarLinks = $sidebar_links' <<<"$user_json")"

        if jq -e \
          --argjson scopes "$desired_scopes" \
          --argjson permissions "$desired_permissions" \
          --argjson sidebar_links "$desired_sidebar_links" \
          '.scopes == $scopes and .permissions == $permissions and ((.sidebarLinks // []) == $sidebar_links)' >/dev/null <<<"$user_json"; then
          return 0
        fi

        api_put \
          "/api/users?username=$(urlencode "$username")" \
          "$(jq -cn --argjson data "$updated_user" '{which:["Scopes","Permissions","SidebarLinks"], data:$data}')" \
          >/dev/null
      }

      wait_for_health
      login

      for group_name in user-files shared-files-read-write-access; do
        ensure_group_membership "$group_name"
      done

      for group_name in shared-files-read-write-access; do
        ensure_allow_group "Shared" "/" "$group_name"
      done

      api_get "/api/users" | jq -c '.[]' | while IFS= read -r user_json; do
        sync_user "$user_json"
      done

      jq -cn --arg timestamp "$(date --iso-8601=seconds)" '{lastSync:$timestamp}' > ${lib.escapeShellArg accessSyncStamp}
      chown filebrowser-quantum:filebrowser-quantum ${lib.escapeShellArg accessSyncStamp}
      chmod 0640 ${lib.escapeShellArg accessSyncStamp}
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "5s";
      User = "root";
    };
  };

  systemd.timers.filebrowser-quantum-access-sync-v1 = {
    description = "Periodic FileBrowser Quantum access convergence";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitActiveSec = "5m";
      Unit = "filebrowser-quantum-access-sync-v1.service";
    };
  };
}
