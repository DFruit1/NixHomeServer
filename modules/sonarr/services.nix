{ config, lib, oauth2Proxy, vars, ... }:

let
  cfg = config.repo.sonarr;
  loopback = vars.networking.loopbackIPv4;
  host = "sonarr.${vars.domain}";
in
{
  options.repo.sonarr.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable Sonarr.";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.sonarr = {
        enable = true;
        openFirewall = false;
        dataDir = "/var/lib/sonarr/.config/NzbDrone";
        settings = {
          update = {
            mechanism = "external";
            automatically = false;
          };
          server = {
            port = vars.networking.ports.sonarr;
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
        "d /var/lib/sonarr 0750 sonarr sonarr - -"
        "d /var/lib/sonarr/.config 0750 sonarr sonarr - -"
        "d /var/lib/sonarr/.config/NzbDrone 0750 sonarr sonarr - -"
      ];

      systemd.services.sonarr = {
        wants = [ "media-automation-storage-layout-v1.service" ];
        after = [ "media-automation-storage-layout-v1.service" ];
        serviceConfig = {
          PrivateUsers = lib.mkForce false;
          SupplementaryGroups = [ "media-automation" ];
          UMask = lib.mkForce "0002";
          ReadWritePaths = [
            "/var/lib/sonarr"
            "/mnt/data/shared/_Videos/_Shows"
            "/mnt/data/shared/_Downloads/qbittorrent"
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "sonarr-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Sonarr";
      clientId = "sonarr-web";
      clientSecretFile = config.age.secrets.sonarrOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.sonarrOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_sonarr";
      domain = host;
      port = vars.networking.ports.oauth2ProxySonarr;
      upstream = "http://${loopback}:${toString vars.networking.ports.sonarr}";
      allowedGroups = [ "media-automation-users" ];
      serviceDependencies = [
        "caddy.service"
        "sonarr.service"
      ];
    })
  ]);
}
