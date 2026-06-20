{ config, lib, oauth2Proxy, vars, ... }:

let
  cfg = config.repo.qbittorrent;
  paths = cfg.paths;
  loopback = vars.networking.loopbackIPv4;
  host = "torrents.${vars.domain}";
in
{
  options.repo.qbittorrent.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable qBittorrent.";
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      services.qbittorrent = {
        enable = true;
        openFirewall = false;
        profileDir = paths.profileDir;
        webuiPort = vars.networking.ports.qbittorrentWeb;
        torrentingPort = vars.networking.ports.qbittorrentTorrent;
        serverConfig = {
          LegalNotice.Accepted = true;
          BitTorrent.Session = {
            DefaultSavePath = paths.completeDir;
            TempPath = paths.incompleteDir;
            TempPathEnabled = true;
            AddTorrentStopped = false;
            DisableAutoTMMByDefault = false;
          };
          Preferences.WebUI = {
            Address = loopback;
            AuthSubnetWhitelist = "127.0.0.1/32";
            AuthSubnetWhitelistEnabled = true;
            LocalHostAuth = false;
          };
        };
      };

      systemd.services.qbittorrent = {
        wants = [ "media-automation-storage-layout-v1.service" ];
        after = [ "media-automation-storage-layout-v1.service" ];
        serviceConfig = {
          PrivateUsers = lib.mkForce false;
          SupplementaryGroups = [ "media-automation" ];
          UMask = "0002";
          ReadWritePaths = [
            paths.profileDir
            paths.downloadRoot
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "qbittorrent-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for qBittorrent";
      clientId = "qbittorrent-web";
      clientSecretFile = config.age.secrets.qbittorrentOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.qbittorrentOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_qbittorrent";
      domain = host;
      port = vars.networking.ports.oauth2ProxyQbittorrent;
      upstream = "http://${loopback}:${toString vars.networking.ports.qbittorrentWeb}";
      allowedGroups = [ "media-automation-users" ];
      serviceDependencies = [
        "caddy.service"
        "qbittorrent.service"
      ];
    })
  ]);
}
