{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  config = lib.mkIf config.nixhomeserver.apps.kavita.enable {
    repo.networking = {
      ports.kavita = {
        port = vars.networking.ports.kavita;
        protocol = "tcp";
        bind = "loopback";
        owner = "kavita";
      };

      caddy.virtualHosts."${vars.kavitaDomain}" = {
        owner = "kavita";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString config.services.kavita.settings.Port}
        '';
      };

      dns.privateHosts."${vars.kavitaDomain}" = {
        owner = "kavita";
        target = "private";
      };
    };
  };
}
