{ config, lib, oauth2Proxy, vars, ... }:

let
  cfg = config.repo.prowlarr;
  loopback = vars.networking.loopbackIPv4;
  host = "prowlarr.${vars.domain}";
in
{
  options.repo.prowlarr.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable Prowlarr.";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.prowlarr = {
        enable = true;
        openFirewall = false;
        dataDir = "/var/lib/prowlarr";
        settings = {
          update = {
            mechanism = "external";
            automatically = false;
          };
          server = {
            port = vars.networking.ports.prowlarr;
            bindaddress = loopback;
          };
          log.analyticsEnabled = false;
          auth = {
            enabled = true;
            method = "External";
            required = "Enabled";
          };
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/prowlarr 0750 prowlarr prowlarr - -"
      ];

      systemd.services.prowlarr.serviceConfig = {
        DynamicUser = lib.mkForce false;
        User = "prowlarr";
        Group = "prowlarr";
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "prowlarr-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Prowlarr";
      clientId = "prowlarr-web";
      clientSecretFile = config.age.secrets.prowlarrOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.prowlarrOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_prowlarr";
      domain = host;
      port = vars.networking.ports.oauth2ProxyProwlarr;
      upstream = "http://${loopback}:${toString vars.networking.ports.prowlarr}";
      allowedGroups = [ "media-automation-users" ];
      serviceDependencies = [
        "caddy.service"
        "prowlarr.service"
      ];
    })
  ]);
}
