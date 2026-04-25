{ config, lib, pkgs, vars, pkgsUnstable, ... }:

let
  kavitaPort = 5000;
  dataDir = "/var/lib/kavita";
in
{
  services.kavita = {
    enable = true;
    package = pkgsUnstable.kavita;
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
        SyncUserSettings = false;
        RolesPrefix = "kavita-";
        RolesClaim = "groups";
        CustomScopes = [ "groups" ];
        DefaultRoles = [ "Login" ];
        DefaultLibraries = [ ];
        DefaultAgeRestriction = 0;
        DefaultIncludeUnknowns = false;
        AutoLogin = false;
        DisablePasswordAuthentication = false;
        ProviderName = "Kanidm";
      };
    };
  };

  users.users.kavita.extraGroups = lib.mkAfter [ "media-library" ];

  systemd.services.kavita.preStart = lib.mkAfter ''
    ${pkgs.replace-secret}/bin/replace-secret '@OIDC_SECRET@' \
      ${config.age.secrets.kavitaClientSecret.path} \
      '${dataDir}/config/appsettings.json'
  '';

  systemd.services.kavita = {
    after = [ "app-state-migration-v1.service" "data-pool-layout.service" ];
    wants = [ "app-state-migration-v1.service" "data-pool-layout.service" ];
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
    path = with pkgs; [
      jq
      sqlite
    ];
    script = ''
      set -euo pipefail

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

      # Kavita 0.8.8.x rejects the lowercase Kanidm group-derived roles used
      # in this repo, so keep OIDC for auth/linking and leave roles local.
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
          | .SyncUserSettings = false
          | .RolesPrefix = "kavita-"
          | .RolesClaim = "groups"
          | .CustomScopes = ["groups"]
          | .DefaultRoles = ["Login"]
          | .DefaultLibraries = []
          | .DefaultAgeRestriction = 0
          | .DefaultIncludeUnknowns = false
          | .Enabled = true
          | .AutoLogin = false
          | .DisablePasswordAuthentication = false
          | .ProviderName = "Kanidm"
        ')"

      if [[ "$current" == "$updated" ]]; then
        exit 0
      fi

      escaped="$(printf '%s' "$updated" | ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g')"
      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update ServerSetting set Value = '$escaped' where Key = 40;"
      /run/current-system/sw/bin/systemctl restart kavita.service
    '';
  };
}
