{ config, lib, oauth2Proxy, vars, ... }:

let
  cfg = config.repo.seerr;
  loopback = vars.networking.loopbackIPv4;
  host = "requests.${vars.domain}";
in
{
  options.repo.seerr.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable the Jellyfin-oriented Seerr request manager.";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.seerr = {
        enable = true;
        port = vars.networking.ports.seerr;
        configDir = "/var/lib/seerr";
        openFirewall = false;
      };

      systemd.services.seerr = {
        wants = [ "network-online.target" ];
        after = [ "network-online.target" ];
        serviceConfig.StateDirectory = lib.mkForce "seerr";
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "seerr-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Seerr";
      clientId = "seerr-web";
      clientSecretFile = config.age.secrets.seerrOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.seerrOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_seerr";
      domain = host;
      port = vars.networking.ports.oauth2ProxySeerr;
      upstream = "http://${loopback}:${toString vars.networking.ports.seerr}";
      allowedGroups = [ "media-automation-users" ];
      serviceDependencies = [
        "caddy.service"
        "seerr.service"
      ];
    })
  ]);
}
