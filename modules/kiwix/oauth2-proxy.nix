{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.kiwixServe;
  kiwixOauth2ProxyPort = 4182;
  proxyArgs = [
    "--provider=oidc"
    "--approval-prompt=auto"
    "--scope=openid profile email groups"
    "--email-domain=*"
    "--upstream=http://127.0.0.1:${toString cfg.port}"
    "--redirect-url=https://${vars.kiwixDomain}/oauth2/callback"
    "--http-address=127.0.0.1:${toString kiwixOauth2ProxyPort}"
    "--client-id=kiwix-web"
    "--client-secret-file=${config.age.secrets.kiwixOauth2ProxyClientSecret.path}"
    "--cookie-secret-file=${config.age.secrets.kiwixOauth2ProxyCookieSecret.path}"
    "--oidc-issuer-url=${vars.kanidmIssuer "kiwix-web"}"
    "--reverse-proxy=true"
    "--set-xauthrequest=true"
    "--pass-user-headers=true"
    "--oidc-groups-claim=groups"
    "--provider-ca-file=/etc/ssl/certs/ca-bundle.crt"
    "--skip-provider-button=true"
    "--code-challenge-method=S256"
    "--allowed-group=users"
    "--cookie-name=_oauth2_proxy_kiwix"
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.kiwix-oauth2-proxy = {
      description = "Dedicated OAuth2 Proxy for Kiwix";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "unbound.service"
        "caddy.service"
        "kanidm.service"
        "kiwix.service"
      ];
      after = [
        "network-online.target"
        "unbound.service"
        "caddy.service"
        "kanidm.service"
        "kiwix.service"
      ];

      serviceConfig = {
        Type = "simple";
        User = "oauth2-proxy";
        Group = "oauth2-proxy";
        ExecStart = "${pkgs.oauth2-proxy}/bin/oauth2-proxy ${lib.concatStringsSep " " (map lib.escapeShellArg proxyArgs)}";
        Restart = "on-failure";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ReadOnlyPaths = [
          config.age.secrets.kiwixOauth2ProxyClientSecret.path
          config.age.secrets.kiwixOauth2ProxyCookieSecret.path
        ];
      };
    };
  };
}
