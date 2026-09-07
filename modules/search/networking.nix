{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "search.${vars.domain}";
in
{
  config = lib.mkIf config.repo.search.enable {
    services.caddy.virtualHosts.${host} = {
      logFormat = null;
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.search}
      '';
    };

    services.unbound.privateHosts.${host} = {
      target = "private";
    };
  };
}
