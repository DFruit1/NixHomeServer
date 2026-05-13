{ config, lib, pkgs, vars, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  cfg = config.services.kiwixServe;
  kiwixOauth2ProxyPort = 4182;
in
{
  config = lib.mkIf cfg.enable (oauth2Proxy.mkSidecarService {
    serviceName = "kiwix-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for Kiwix";
    clientId = "kiwix-web";
    clientSecretFile = config.age.secrets.kiwixOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.kiwixOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_kiwix";
    domain = vars.kiwixDomain;
    port = kiwixOauth2ProxyPort;
    upstream = "http://127.0.0.1:${toString cfg.port}";
    allowedGroups = [ "users" ];
    serviceDependencies = [
      "caddy.service"
      "kiwix.service"
    ];
  });
}
