{ config, vars, pkgs, ... }:

let
  oauth2ProxyPort = 4180;
  oauth2ProxyRuntimeDir = "/run/oauth2-proxy";
  oauth2ProxyKeyFilePath = "${oauth2ProxyRuntimeDir}/oauth2-proxy.env";
  oauth2ProxyClientSecretPath = "${oauth2ProxyRuntimeDir}/client-secret";
in
{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    approvalPrompt = "auto";
    oidcIssuerUrl = vars.kanidmIssuer "oauth2-proxy";
    scope = "openid profile email";
    email.domains = [ "*" ];
    upstream = [ "http://127.0.0.1:${toString config.services.copyparty.settings.p}" ];
    redirectURL = "https://${vars.filesDomain}/oauth2/callback";
    httpAddress = "127.0.0.1:${toString oauth2ProxyPort}";
    clientID = "oauth2-proxy";
    keyFile = oauth2ProxyKeyFilePath;
    reverseProxy = true;
    setXauthrequest = true;
    extraConfig = {
      "code-challenge-method" = "S256";
      "pass-user-headers" = true;
      "provider-ca-file" = "/etc/ssl/certs/ca-bundle.crt";
      "skip-provider-button" = true;
    };
  };

  systemd.services.oauth2-proxy-secret-materialize = {
    description = "Materialize raw oauth2-proxy secrets";
    wantedBy = [ "multi-user.target" ];
    before = [ "oauth2-proxy.service" "kanidm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      read_secret_value() {
        local file="$1"
        local key="$2"
        if grep -q "^''${key}=" "$file"; then
          sed -n "s/^''${key}=//p" "$file" | head -n1 | tr -d '\r\n'
        else
          tr -d '\r\n' < "$file"
        fi
      }

      install -d -m 0750 -o root -g root ${oauth2ProxyRuntimeDir}

      client_secret="$(read_secret_value ${config.age.secrets.oauth2ProxyClientSecret.path} OAUTH2_PROXY_CLIENT_SECRET)"
      cookie_secret="$(read_secret_value ${config.age.secrets.oauth2ProxyCookieSecret.path} OAUTH2_PROXY_COOKIE_SECRET)"

      printf '%s' "$client_secret" > ${oauth2ProxyClientSecretPath}
      printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\nOAUTH2_PROXY_COOKIE_SECRET=%s\n' "$client_secret" "$cookie_secret" > ${oauth2ProxyKeyFilePath}

      chown root:kanidm ${oauth2ProxyClientSecretPath}
      chmod 0440 ${oauth2ProxyClientSecretPath}
      chown root:oauth2-proxy ${oauth2ProxyKeyFilePath}
      chmod 0440 ${oauth2ProxyKeyFilePath}
    '';
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
  };

  systemd.services.oauth2-proxy = {
    wants = [
      "oauth2-proxy-secret-materialize.service"
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
    ];
    after = [
      "oauth2-proxy-secret-materialize.service"
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
    ];
  };

  users.users.oauth2-proxy.extraGroups = [ "caddy" ];
}
