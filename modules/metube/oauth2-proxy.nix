{ config, lib, pkgs, vars, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  metubeOauth2ProxyPort = 4183;
  metubeListenPort = 8083;
in
{
  config = oauth2Proxy.mkSidecarService {
    serviceName = "metube-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for MeTube";
    clientId = "metube-web";
    clientSecretFile = config.age.secrets.metubeOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.metubeOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_metube";
    domain = vars.metubeDomain;
    port = metubeOauth2ProxyPort;
    upstream = "http://127.0.0.1:${toString metubeListenPort}";
    allowedGroups = [ "metube-users" ];
    serviceDependencies = [
      "caddy.service"
      "metube-quadlet-refresh.service"
    ];
    upstreamCheck = {
      displayName = "MeTube";
      url = "http://127.0.0.1:${toString metubeListenPort}/";
    };
  };
}
