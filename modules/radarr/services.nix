{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  cfg = config.repo.radarr;
  loopback = vars.networking.loopbackIPv4;
  host = "radarr.${vars.domain}";
in
{
  options.repo.radarr.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable Radarr.";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.radarr = {
        enable = true;
        openFirewall = false;
        dataDir = "/var/lib/radarr/.config/Radarr";
        settings = {
          update = {
            mechanism = "external";
            automatically = false;
          };
          server = {
            port = vars.networking.ports.radarr;
            bindaddress = loopback;
          };
          log.analyticsEnabled = false;
          auth = {
            enabled = true;
            method = "Forms";
            required = "DisabledForLocalAddresses";
          };
        };
      };

      systemd.tmpfiles.rules = [
        "d /var/lib/radarr 0750 radarr radarr - -"
        "d /var/lib/radarr/.config 0750 radarr radarr - -"
        "d /var/lib/radarr/.config/Radarr 0750 radarr radarr - -"
      ];

      systemd.services.radarr = {
        wants = [ "media-automation-storage-layout-v1.service" ];
        after = [ "media-automation-storage-layout-v1.service" ];
        preStart = ''
          config_xml=/var/lib/radarr/.config/Radarr/config.xml
          if [[ -f "$config_xml" ]]; then
            ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
              -u '/Config/AuthenticationMethod' -v 'Forms' \
              -u '/Config/AuthenticationRequired' -v 'DisabledForLocalAddresses' \
              "$config_xml"
          fi
        '';
        serviceConfig = {
          PrivateUsers = lib.mkForce false;
          SupplementaryGroups = [ "media-automation" ];
          UMask = lib.mkForce "0002";
          ReadWritePaths = [
            "/var/lib/radarr"
            "${vars.sharedRoot}/_Videos/_Movies"
            "${vars.sharedRoot}/_Downloads/qbittorrent"
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "radarr-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Radarr";
      clientId = "radarr-web";
      clientSecretFile = config.age.secrets.radarrOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.radarrOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_radarr";
      domain = host;
      port = vars.networking.ports.oauth2ProxyRadarr;
      upstream = "http://${loopback}:${toString vars.networking.ports.radarr}";
      allowedGroups = [ "media-automation-users" ];
      serviceDependencies = [
        "caddy.service"
        "radarr.service"
      ];
    })
  ]);
}
