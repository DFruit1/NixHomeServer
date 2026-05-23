{ config, oauth2Proxy, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  oauth2ProxyPort = vars.networking.ports.oauth2ProxyUploads;
  host = "uploads.${vars.domain}";
  oauth2ProxyRuntimeDir = "/run/oauth2-proxy";
  oauth2ProxyKeyFilePath = "${oauth2ProxyRuntimeDir}/oauth2-proxy.env";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
in
{
  services.oauth2-proxy = oauth2Proxy.mkNixosService
    {
      clientId = "oauth2-proxy";
      domain = host;
      port = oauth2ProxyPort;
      upstream = "http://${loopback}:${toString config.services.copyparty.settings.p}";
      allowedGroups = [ webAccessGroup ];
      extraConfig = {
        "session-cookie-minimal" = true;
        "skip-auth-preflight" = true;
        "upstream-timeout" = "30m0s";
      };
    } // {
    keyFile = oauth2ProxyKeyFilePath;
    cookie.expire = vars.uploadsOauth2ProxyCookieExpire;
  };

  systemd.services.oauth2-proxy = {
    wants = [
      "oauth2-proxy-secret-materialize.service"
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
    ];
    after = [
      "oauth2-proxy-secret-materialize.service"
      "network-online.target"
      "unbound.service"
      "caddy.service"
      "kanidm.service"
      "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
    ];
  };
}
