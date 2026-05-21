{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  config = lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable {
    repo.networking = {
      ports = {
        youtube-downloader = {
          port = vars.networking.ports.youtubeDownloader;
          protocol = "tcp";
          bind = "loopback";
          owner = "youtube-downloader";
        };
        oauth2-proxy-downloads = {
          port = vars.networking.ports.oauth2ProxyDownloads;
          protocol = "tcp";
          bind = "loopback";
          owner = "youtube-downloader";
        };
      };

      caddy.virtualHosts."${vars.downloadsDomain}" = {
        owner = "youtube-downloader";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyDownloads} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      dns.privateHosts."${vars.downloadsDomain}" = {
        owner = "youtube-downloader";
        target = "private";
      };
    };
  };
}
