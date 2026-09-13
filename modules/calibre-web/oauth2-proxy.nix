{ config, lib, oauth2Proxy, vars, ... }:

let
  cfg = config.repo.calibreWeb;
  loopback = vars.networking.loopbackIPv4;
  host = "calibre.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable (oauth2Proxy.mkSidecarService {
    serviceName = "calibre-web-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for Calibre-Web";
    clientId = "calibre-web-web";
    clientSecretFile = config.age.secrets.calibreWebOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.calibreWebOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_calibre_web";
    domain = host;
    port = vars.networking.ports.oauth2ProxyCalibreWeb;
    upstream = "http://${loopback}:${toString cfg.port}";
    allowedGroups = [ "calibre-web-users" ];
    serviceDependencies = [
      "caddy.service"
      "calibre-web.service"
      "calibre-web-library-layout-v1.service"
    ];
  });
}
