{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
in
{
  config = lib.mkIf config.nixhomeserver.apps.kiwix.enable {
    repo.networking = {
      ports = {
        kiwix = {
          port = vars.networking.ports.kiwix;
          protocol = "tcp";
          bind = "loopback";
          owner = "kiwix";
        };
        oauth2-proxy-kiwix = {
          port = vars.networking.ports.oauth2ProxyKiwix;
          protocol = "tcp";
          bind = "loopback";
          owner = "kiwix";
        };
      };

      caddy.virtualHosts."${vars.kiwixDomain}" = {
        owner = "kiwix";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyKiwix} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host {host}
          }
        '';
      };

      dns.privateHosts."${vars.kiwixDomain}" = {
        owner = "kiwix";
        target = "private";
      };
    };
  };
}
