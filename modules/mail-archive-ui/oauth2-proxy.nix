{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
  mailArchiveOauth2ProxyPort = 4181;
  proxyArgs = [
    "--provider=oidc"
    "--approval-prompt=auto"
    "--scope=openid profile email groups"
    "--email-domain=*"
    "--upstream=http://127.0.0.1:${toString cfg.port}"
    "--redirect-url=https://${vars.emailsDomain}/oauth2/callback"
    "--http-address=127.0.0.1:${toString mailArchiveOauth2ProxyPort}"
    "--client-id=mail-archive-web"
    "--client-secret-file=${config.age.secrets.mailArchiveOauth2ProxyClientSecret.path}"
    "--cookie-secret-file=${config.age.secrets.mailArchiveOauth2ProxyCookieSecret.path}"
    "--oidc-issuer-url=${vars.kanidmIssuer "mail-archive-web"}"
    "--reverse-proxy=true"
    "--set-xauthrequest=true"
    "--pass-user-headers=true"
    "--oidc-groups-claim=groups"
    "--provider-ca-file=/etc/ssl/certs/ca-bundle.crt"
    "--skip-provider-button=true"
    "--code-challenge-method=S256"
    "--allowed-group=mail-archive-users"
    "--cookie-name=_oauth2_proxy_mail_archive"
  ];
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.mail-archive-oauth2-proxy = {
      description = "Dedicated OAuth2 Proxy for the private mail archive UI";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "unbound.service"
        "caddy.service"
        "kanidm.service"
        "mail-archive-ui.service"
      ];
      after = [
        "network-online.target"
        "unbound.service"
        "caddy.service"
        "kanidm.service"
        "mail-archive-ui.service"
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
          config.age.secrets.mailArchiveOauth2ProxyClientSecret.path
          config.age.secrets.mailArchiveOauth2ProxyCookieSecret.path
        ];
      };
    };
  };
}
