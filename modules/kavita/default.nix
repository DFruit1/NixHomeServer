{ config, lib, pkgs, vars, ... }:

let
  enabled = config.nixhomeserver.apps.kavita.enable;
  kavitaPort = vars.networking.ports.kavita;
  dataDir = "/var/lib/kavita";
  dbPath = "${dataDir}/config/kavita.db";
  kavitaScanCronExpression = vars.apps.books.autoScanCronExpression or "*/15 * * * *";
  cleanupUsers = vars.staleReferenceCleanup.users or false;
  cleanupShared = vars.staleReferenceCleanup.shared or false;
  baseKavitaPackage = pkgs.callPackage ./package.nix { };
  kavitaPackage = baseKavitaPackage.overrideAttrs (old: {
    backend = old.backend.overrideAttrs (backendOld: {
      patches = (backendOld.patches or [ ]) ++ [
        ./patches/disable-update-notifications.patch
        ./patches/fix-epub-relative-resource-resolution.patch
        ./patches/scan-root-level-library-files.patch
      ];
    });
  });
  kavitaLibraryWatchConfigPath = with pkgs; [
    coreutils
    perl
    sqlite
  ];
  kavitaOidcBootstrapPath = with pkgs; [
    jq
    sqlite
  ];
  kavitaStaleReferenceCleanupPath = with pkgs; [
    coreutils
    curl
    gnugrep
    sqlite
  ];
in
{
  imports = [
    ./storage.nix
  ];

  config = lib.mkIf enabled {
    services.kavita = {
      enable = true;
      package = kavitaPackage;
      dataDir = dataDir;
      tokenKeyFile = config.age.secrets.kavitaTokenKey.path;
      settings = {
        Port = kavitaPort;
        IpAddresses = "${vars.networking.loopbackIPv4},${vars.networking.loopbackIPv6}";
        OpenIdConnectSettings = {
          Enabled = true;
          Authority = vars.kanidmIssuer "kavita-web";
          ClientId = "kavita-web";
          Secret = "@OIDC_SECRET@";
          ProvisionAccounts = true;
          RequireVerifiedEmail = true;
          SyncUserSettings = true;
          RolesPrefix = "";
          RolesClaim = "kavita_roles";
          CustomScopes = [ "kavita_roles" ];
          DefaultRoles = [ ];
          DefaultLibraries = [ ];
          DefaultAgeRestriction = 0;
          DefaultIncludeUnknowns = false;
          AutoLogin = true;
          DisablePasswordAuthentication = true;
          ProviderName = "Kanidm";
        };
      };
    };

    systemd.services.kavita.preStart = lib.mkAfter ''
      ${pkgs.replace-secret}/bin/replace-secret '@OIDC_SECRET@' \
        ${config.age.secrets.kavitaClientSecret.path} \
        '${dataDir}/config/appsettings.json'
    '';

    systemd.timers.kavita-stale-reference-cleanup = {
      description = "Regularly run Kavita stale reference maintenance";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15m";
        OnUnitActiveSec = "15m";
        AccuracySec = "1m";
        RandomizedDelaySec = "2m";
        Persistent = true;
        Unit = "kavita-stale-reference-cleanup.service";
      };
    };

    systemd.services.kavita-stale-reference-cleanup = {
      description = "Run Kavita maintenance for enabled media scopes";
      after = [
        "kavita.service"
        "kavita-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      wants = [
        "kavita.service"
        "kavita-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      path = kavitaStaleReferenceCleanupPath;
      script = ''
        set -euo pipefail

        cleanup_users=${if cleanupUsers then "true" else "false"}
        cleanup_shared=${if cleanupShared then "true" else "false"}
        users_root=${lib.escapeShellArg vars.usersRoot}
        shared_root=${lib.escapeShellArg vars.sharedRoot}
        db=${lib.escapeShellArg dbPath}
        base_url="http://${vars.networking.loopbackIPv4}:${toString kavitaPort}"
        api_key_file="${dataDir}/config/nixos-stale-cleanup-api-key"

        if [[ "$cleanup_users" != "true" && "$cleanup_shared" != "true" ]]; then
          echo "Kavita stale reference cleanup is disabled for users and shared scopes"
          exit 0
        fi

        if [[ "$cleanup_users" == "true" && ! -d "$users_root" ]]; then
          echo "Kavita users cleanup requested but $users_root is missing; skipping cleanup"
          exit 0
        fi

        if [[ "$cleanup_shared" == "true" && ! -d "$shared_root" ]]; then
          echo "Kavita shared cleanup requested but $shared_root is missing; skipping cleanup"
          exit 0
        fi

        for _ in $(seq 1 30); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || {
          echo "Kavita database not found at $db; skipping stale reference cleanup"
          exit 0
        }

        scoped_library_count=0
        while IFS= read -r table_name; do
          [[ -n "$table_name" ]] || continue
          if ! sqlite3 -readonly "$db" "pragma table_info('$table_name');" \
            | grep -Eq '^[0-9]+\|Path\|'; then
            continue
          fi

          while IFS= read -r library_path; do
            [[ -n "$library_path" ]] || continue
            if [[ "$cleanup_users" == "true" && ( "$library_path" == "$users_root" || "$library_path" == "$users_root/"* ) ]]; then
              scoped_library_count=$((scoped_library_count + 1))
              continue
            fi
            if [[ "$cleanup_shared" == "true" && ( "$library_path" == "$shared_root" || "$library_path" == "$shared_root/"* ) ]]; then
              scoped_library_count=$((scoped_library_count + 1))
            fi
          done < <(sqlite3 -readonly -cmd '.timeout 5000' "$db" "select Path from \"$table_name\";" 2>/dev/null || true)
        done < <(sqlite3 -readonly "$db" "select name from sqlite_master where type = 'table';")

        if (( scoped_library_count == 0 )); then
          echo "No Kavita libraries found under enabled stale cleanup scopes"
          exit 0
        fi

        ready=0
        for _ in $(seq 1 60); do
          if curl --silent --show-error --fail --max-time 5 "$base_url/api/Server/server-info-slim" >/dev/null; then
            ready=1
            break
          fi
          sleep 1
        done
        (( ready == 1 )) || {
          echo "Kavita HTTP endpoint is not ready yet; skipping stale reference cleanup"
          exit 0
        }

        if [[ -r "$api_key_file" ]]; then
          api_key="$(< "$api_key_file")"
          if [[ -n "$api_key" ]]; then
            echo "Running Kavita server cleanup through the local API"
            curl \
              --silent \
              --show-error \
              --fail \
              --max-time 600 \
              -X POST \
              -H "x-api-key: $api_key" \
              "$base_url/api/Server/cleanup" \
              >/dev/null
            exit 0
          fi
        fi

        if curl \
          --silent \
          --show-error \
          --fail \
          --max-time 600 \
          -X POST \
          "$base_url/api/Server/cleanup" \
          >/dev/null; then
          echo "Ran Kavita server cleanup through unauthenticated local API access"
          exit 0
        fi

        echo "Kavita API cleanup is not authenticated; relying on native folder watching and scan cron"
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.kavita-oidc-bootstrap = {
      description = "Synchronize Kavita OIDC settings";
      wantedBy = [ "multi-user.target" ];
      after = [
        "kavita.service"
        "caddy.service"
        "kanidm.service"
      ];
      wants = [
        "kavita.service"
        "caddy.service"
        "kanidm.service"
      ];
      path = kavitaOidcBootstrapPath;
      script = ''
        set -euo pipefail

        run_sqlite_write() {
          local sql="$1"
          local attempt_output=""

          for _ in $(seq 1 30); do
            if attempt_output="$(${pkgs.sqlite}/bin/sqlite3 "$db" "$sql" 2>&1)"; then
              return 0
            fi

            if [[ "$attempt_output" == *"database is locked"* ]]; then
              sleep 1
              continue
            fi

            printf '%s\n' "$attempt_output" >&2
            return 1
          done

          printf '%s\n' "Timed out waiting for Kavita database write lock to clear" >&2
          return 1
        }

        db="${dataDir}/config/kavita.db"
        for _ in $(seq 1 30); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || {
          echo "Kavita database not found at $db" >&2
          exit 1
        }

        table_ready=""
        for _ in $(seq 1 30); do
          table_ready="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
            "select count(*) from sqlite_master where type = 'table' and name = 'ServerSetting';" \
            2>/dev/null || true)"
          [[ "$table_ready" == "1" ]] && break
          sleep 1
        done
        [[ "$table_ready" == "1" ]] || exit 0

        client_secret="$(< ${config.age.secrets.kavitaClientSecret.path})"
        current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 40;" 2>/dev/null || true)"
        [[ -n "$current" ]] || exit 0

        updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
          --arg authority "${vars.kanidmIssuer "kavita-web"}" \
          --arg clientId "kavita-web" \
          --arg secret "$client_secret" \
          '
            .Authority = $authority
            | .ClientId = $clientId
            | .Secret = $secret
            | .ProvisionAccounts = true
            | .RequireVerifiedEmail = true
            | .SyncUserSettings = true
            | .RolesPrefix = ""
            | .RolesClaim = "kavita_roles"
            | .CustomScopes = ["kavita_roles"]
            | .DefaultRoles = []
            | .DefaultLibraries = []
            | .DefaultAgeRestriction = 0
            | .DefaultIncludeUnknowns = false
            | .Enabled = true
            | .AutoLogin = true
            | .DisablePasswordAuthentication = true
            | .ProviderName = "Kanidm"
          ')"

        if [[ "$current" == "$updated" ]]; then
          exit 0
        fi

        escaped="$(printf '%s' "$updated" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g')"
        run_sqlite_write "update ServerSetting set Value = '$escaped' where Key = 40;"
        /run/current-system/sw/bin/systemctl restart kavita.service
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.kavita-library-watch-config-v1 = {
      description = "Enable Kavita native folder watchers";
      wantedBy = [ "multi-user.target" ];
      after = [ "kavita.service" ];
      wants = [ "kavita.service" ];
      path = kavitaLibraryWatchConfigPath;
      script = ''
        set -euo pipefail

        db=${lib.escapeShellArg dbPath}
        scan_cron=${lib.escapeShellArg kavitaScanCronExpression}

        for _ in $(seq 1 30); do
          [[ -f "$db" ]] && break
          sleep 1
        done
        [[ -f "$db" ]] || exit 0

        libraries_needing_watchers="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select count(*) from Library where FolderWatching != 1;" 2>/dev/null || true)"
        [[ "$libraries_needing_watchers" =~ ^[0-9]+$ ]] || exit 0

        global_folder_watching="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 17;" 2>/dev/null || true)"
        task_scan="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
          "select Value from ServerSetting where Key = 0;" 2>/dev/null || true)"

        changed=0

        escape_sql() {
          printf '%s' "$1" | perl -pe 's/\x27/\x27\x27/g'
        }

        run_sqlite_write() {
          local sql="$1"
          local attempt_output=""

          for _ in $(seq 1 30); do
            if attempt_output="$(${pkgs.sqlite}/bin/sqlite3 "$db" "$sql" 2>&1)"; then
              return 0
            fi

            if [[ "$attempt_output" == *"database is locked"* ]]; then
              sleep 1
              continue
            fi

            printf '%s\n' "$attempt_output" >&2
            return 1
          done

          printf '%s\n' "Timed out waiting for Kavita database write lock to clear" >&2
          return 1
        }

        if [[ "$libraries_needing_watchers" != "0" ]]; then
          run_sqlite_write "update Library set FolderWatching = 1 where FolderWatching != 1;"
          changed=1
        fi

        if [[ "$global_folder_watching" != "true" ]]; then
          run_sqlite_write "update ServerSetting set Value = 'true' where Key = 17;"
          changed=1
        fi

        if [[ "$task_scan" != "$scan_cron" ]]; then
          escaped_scan_cron="$(escape_sql "$scan_cron")"
          run_sqlite_write "update ServerSetting set Value = '$escaped_scan_cron' where Key = 0;"
          changed=1
        fi

        if (( changed != 0 )); then
          /run/current-system/sw/bin/systemctl restart kavita.service
        fi
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };

}
