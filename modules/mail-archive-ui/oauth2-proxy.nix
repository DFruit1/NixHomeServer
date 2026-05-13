{ config, lib, pkgs, vars, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  cfg = config.services.mail-archive-ui;
  mailArchiveOauth2ProxyPort = 4181;
in
{
  config = lib.mkIf cfg.enable (oauth2Proxy.mkSidecarService {
    serviceName = "mail-archive-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for the private mail archive UI";
    clientId = "mail-archive-web";
    clientSecretFile = config.age.secrets.mailArchiveOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.mailArchiveOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_mail_archive";
    domain = vars.emailsDomain;
    port = mailArchiveOauth2ProxyPort;
    upstream = "http://127.0.0.1:${toString cfg.port}";
    allowedGroups = [ "mail-archive-users" ];
    serviceDependencies = [ "mail-archive-ui.service" ];
    upstreamCheck = {
      displayName = "Mail Archive UI";
      url = "http://127.0.0.1:${toString cfg.port}/healthz";
      okStatusCodes = [
        "200"
        "503"
      ];
    };
    restartSec = 5;
  });
}
