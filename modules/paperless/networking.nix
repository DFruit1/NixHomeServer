{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  config = lib.mkIf config.nixhomeserver.apps.paperless.enable {
    repo.networking = {
      ports.paperless = {
        port = vars.networking.ports.paperless;
        protocol = "tcp";
        bind = "loopback";
        owner = "paperless";
      };

      caddy.virtualHosts."${vars.paperlessDomain}" = {
        owner = "paperless";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString config.services.paperless.port}
        '';
      };

      dns.privateHosts."${vars.paperlessDomain}" = {
        owner = "paperless";
        target = "private";
      };
    };
  };
}
