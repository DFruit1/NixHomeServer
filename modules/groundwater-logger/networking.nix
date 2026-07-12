{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "groundwater.${vars.domain}";
in
{
  config = lib.mkIf config.repo.groundwaterLogger.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.groundwaterLogger} {
          header_up X-Forwarded-Proto https
        }
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
