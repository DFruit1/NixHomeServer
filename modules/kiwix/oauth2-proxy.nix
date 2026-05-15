{ config, lib, pkgs, vars, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  cfg = config.services.kiwixServe;
  loopback = vars.networking.loopbackIPv4;
  kiwixOauth2ProxyPort = vars.networking.ports.oauth2ProxyKiwix;
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
    upstream = "http://${loopback}:${toString cfg.port}";
    allowedGroups = [ "users" ];
    serviceDependencies = [
      "caddy.service"
      "kiwix.service"
    ];
  });
}
