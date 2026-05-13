{ config, lib, pkgs, vars, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  glancesPort = config.services.glances.port;
  glancesOauth2ProxyPort = 4184;
in
{
  config = lib.mkIf config.services.glances.enable (oauth2Proxy.mkSidecarService {
    serviceName = "glances-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for Glances";
    clientId = "glances-web";
    clientSecretFile = config.age.secrets.glancesOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.glancesOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_glances";
    domain = vars.monitorDomain;
    port = glancesOauth2ProxyPort;
    upstream = "http://127.0.0.1:${toString glancesPort}";
    allowedGroups = [ "glances-users" ];
    serviceDependencies = [
      "caddy.service"
      "glances.service"
    ];
    upstreamCheck = {
      displayName = "Glances";
      url = "http://127.0.0.1:${toString glancesPort}/";
    };
    restartSec = 5;
  });
}
