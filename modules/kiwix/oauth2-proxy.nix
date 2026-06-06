{ config, lib, oauth2Proxy, vars, ... }:

let
  cfg = config.services.kiwixServe;
  loopback = vars.networking.loopbackIPv4;
  kiwixOauth2ProxyPort = vars.networking.ports.oauth2ProxyKiwix;
  host = "wiki.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable (oauth2Proxy.mkSidecarService {
    serviceName = "kiwix-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for Kiwix";
    clientId = "kiwix-web";
    clientSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.kiwixOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_kiwix";
    domain = host;
    port = kiwixOauth2ProxyPort;
    upstream = "http://${loopback}:${toString cfg.port}";
    allowedGroups = [ "users" ];
    serviceDependencies = [
      "caddy.service"
      "kiwix-serve.service"
    ];
  });
}
