{ lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "ytdownload.${vars.domain}";
  nativeHost = "ytdownload-app.${vars.domain}";
  # The native host proxies straight to the application, which authenticates
  # the request itself from a Kanidm bearer token. Every header the app trusts
  # for identity must be stripped first so the direct path cannot forge one.
  spoofableHeaders = [
    "X-Auth-Request-User"
    "X-Auth-Request-Login"
    "X-Auth-Request-Email"
    "X-Auth-Request-Groups"
    "X-Auth-Request-Preferred-Username"
    "X-Forwarded-User"
    "X-Forwarded-Login"
    "X-Forwarded-Email"
    "X-Forwarded-Groups"
    "X-Forwarded-Preferred-Username"
    "Remote-User"
    "Remote_User"
    "Remote-Groups"
    "Remote-Group"
    "X-WebAuth-User"
    "X_WebAuth_User"
  ];
  stripSpoofableHeaders = lib.concatStringsSep "\n"
    (map (header: "request_header -${header}") spoofableHeaders);
in
{
  services.caddy.virtualHosts.${host} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      handle {
        reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyDownloads} {
          header_up X-Forwarded-Proto https
        }
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };

  # Private, non-user-facing endpoint for the native desktop and Android
  # clients. It is published on the LAN only, has no Cloudflare ingress, and
  # bypasses the browser authentication gateway on purpose.
  services.caddy.virtualHosts.${nativeHost} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      @root path /
      handle @root {
        respond "YouTube Downloader API" 200
      }
      @api path /api/*
      handle @api {
        ${stripSpoofableHeaders}
        reverse_proxy http://${loopback}:${toString vars.networking.ports.youtubeDownloader}
      }
      handle {
        respond "Not Found" 404
      }
    '';
  };

  services.unbound.privateHosts.${nativeHost} = {
    target = "private";
    publishOnLan = true;
    publishOnNetbird = true;
  };

  # The native API is bearer-authenticated and API-only, so it can be reached
  # away from home through the tunnel without the browser login gateway.
  services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress.${nativeHost} = {
    service = "https://${loopback}:${toString vars.networking.ports.https}";
    originRequest.originServerName = nativeHost;
  };
}
