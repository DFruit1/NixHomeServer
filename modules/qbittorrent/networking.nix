{ config, lib, vars, ... }:

let
  cfg = config.repo.qbittorrent;
  loopback = vars.networking.loopbackIPv4;
  lanIface = vars.networking.interfaces.lan;
  torrentPort = vars.networking.ports.qbittorrentTorrent;
  host = "torrents.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyQbittorrent} {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };

    networking.firewall.interfaces.${lanIface} = {
      allowedTCPPorts = [ torrentPort ];
      allowedUDPPorts = [ torrentPort ];
    };
  };
}
