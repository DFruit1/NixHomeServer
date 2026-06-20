{ config, lib, vars, ... }:

let
  cfg = config.repo.seerr;
  loopback = vars.networking.loopbackIPv4;
  host = "requests.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    services.caddy.virtualHosts.${host} = {
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxySeerr} {
          header_up X-Forwarded-Proto https
          header_up X-Forwarded-Host {host}
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
