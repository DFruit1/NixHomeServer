{ config, lib, pkgs, vars, pkgsUnstable, ... }:

{
  services.kavita = {
    enable = true;
    package = pkgsUnstable.kavita;
    dataDir = "${vars.dataRoot}/kavita";
    tokenKeyFile = config.age.secrets.kavitaTokenKey.path;
    settings = {
      Port = vars.kavitaPort;
      IpAddresses = "127.0.0.1,::1";
      OpenIdConnectSettings = {
        Authority = vars.kanidmIssuer "kavita-web";
        ClientId = "kavita-web";
        Secret = "@OIDC_SECRET@";
        CustomScopes = [ "groups" ];
      };
    };
  };

  systemd.services.kavita.preStart = lib.mkAfter ''
    ${pkgs.replace-secret}/bin/replace-secret '@OIDC_SECRET@' \
      ${config.age.secrets.kavitaClientSecret.path} \
      '${vars.dataRoot}/kavita/config/appsettings.json'
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
    path = with pkgs; [
      jq
      sqlite
    ];
    script = ''
      set -euo pipefail

      db="${vars.dataRoot}/kavita/config/kavita.db"
      for _ in $(seq 1 30); do
        [[ -f "$db" ]] && break
        sleep 1
      done
      [[ -f "$db" ]] || {
        echo "Kavita database not found at $db" >&2
        exit 1
      }

      client_secret="$(< ${config.age.secrets.kavitaClientSecret.path})"
      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select Value from ServerSetting where Key = 40;")"
      [[ -n "$current" ]] || {
        echo "Kavita OIDC settings row is missing" >&2
        exit 1
      }

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
          | .RolesPrefix = "kavita-"
          | .RolesClaim = "groups"
          | .CustomScopes = ["groups"]
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
