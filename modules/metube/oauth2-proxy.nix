{ config, lib, pkgs, vars, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  loopback = vars.networking.loopbackIPv4;
  metubeOauth2ProxyPort = vars.networking.ports.oauth2ProxyMetube;
  metubeListenPort = vars.networking.ports.metube;
in
{
  config = lib.mkIf config.nixhomeserver.apps.metube.enable (oauth2Proxy.mkSidecarService {
    serviceName = "metube-oauth2-proxy";
    description = "Dedicated OAuth2 Proxy for MeTube";
    clientId = "metube-web";
    clientSecretFile = config.age.secrets.metubeOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.metubeOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_metube";
    domain = vars.metubeDomain;
    port = metubeOauth2ProxyPort;
    upstream = "http://${loopback}:${toString metubeListenPort}";
    allowedGroups = [ "metube-users" ];
    serviceDependencies = [
      "caddy.service"
      "youtube-downloader.service"
    ];
    upstreamCheck = {
      displayName = "YouTube downloader";
      url = "http://${loopback}:${toString metubeListenPort}/healthz";
    };
    extraProxyArgs = [
      "--prefer-email-to-user=true"
      "--api-route=^/api/"
      "--api-route=^/ngsw-worker\\.js$"
      "--api-route=^/ngsw\\.json"
      "--api-route=^/custom-service-worker\\.js$"
    ];
  });
}
