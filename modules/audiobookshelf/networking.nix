{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  port = vars.networking.ports.audiobookshelf;
in
{
  config = lib.mkIf config.nixhomeserver.apps.audiobookshelf.enable {
    repo.networking = {
      ports.audiobookshelf = {
        inherit port;
        protocol = "tcp";
        bind = "loopback";
        owner = "audiobookshelf";
      };

      caddy.virtualHosts."${vars.audiobooksDomain}" = {
        owner = "audiobookshelf";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString config.services.audiobookshelf.port}
        '';
      };

      dns.privateHosts."${vars.audiobooksDomain}" = {
        owner = "audiobookshelf";
        target = "private";
      };
    };
  };
}
