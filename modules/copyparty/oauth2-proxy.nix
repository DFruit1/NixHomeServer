{ config, lib, vars, pkgs, ... }:

let
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
  loopback = vars.networking.loopbackIPv4;
  oauth2ProxyPort = vars.networking.ports.oauth2ProxyUploads;
  oauth2ProxyRuntimeDir = "/run/oauth2-proxy";
  oauth2ProxyKeyFilePath = "${oauth2ProxyRuntimeDir}/oauth2-proxy.env";
in
{
  services.oauth2-proxy = oauth2Proxy.mkNixosService
    {
      clientId = "oauth2-proxy";
      domain = vars.uploadsDomain;
      port = oauth2ProxyPort;
      upstream = "http://${loopback}:${toString config.services.copyparty.settings.p}";
      allowedGroups = [ "user-files" ];
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
