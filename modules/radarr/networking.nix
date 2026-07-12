{ config, lib, vars, ... }:

let
  cfg = config.repo.radarr;
  loopback = vars.networking.loopbackIPv4;
  host = "radarr.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyRadarr} {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
