{ config, lib, pkgs, vars, ... }:

let
  kavitaPort = 5000;
  dataDir = "/var/lib/kavita";
  dbPath = "${dataDir}/config/kavita.db";
  baseKavitaPackage = pkgs.callPackage ./package.nix { };
  kavitaPackage = baseKavitaPackage.overrideAttrs (old: {
    backend = old.backend.overrideAttrs (backendOld: {
      patches = (backendOld.patches or [ ]) ++ [
        ./patches/fix-epub-relative-resource-resolution.patch
      ];
    });
  });
  kavitaLibraryWatchConfigPath = with pkgs; [
    sqlite
  ];
  kavitaOidcBootstrapPath = with pkgs; [
    jq
    sqlite
  ];
in
{
  imports = [
    ./storage.nix
  ];

  services.kavita = {
    enable = true;
    package = kavitaPackage;
    dataDir = dataDir;
    tokenKeyFile = config.age.secrets.kavitaTokenKey.path;
    settings = {
      Port = kavitaPort;
      IpAddresses = "127.0.0.1,::1";
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

      changed=0

      if [[ "$libraries_needing_watchers" != "0" ]]; then
        ${pkgs.sqlite}/bin/sqlite3 "$db" "update Library set FolderWatching = 1 where FolderWatching != 1;"
        changed=1
      fi

      if [[ "$global_folder_watching" != "true" ]]; then
        ${pkgs.sqlite}/bin/sqlite3 "$db" "update ServerSetting set Value = 'true' where Key = 17;"
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

}
