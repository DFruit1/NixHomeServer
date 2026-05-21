{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  lanIface = vars.networking.interfaces.lan;
  ports = vars.networking.ports;
in
{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    repo.networking = {
      ports = {
        jellyfin = {
          port = ports.jellyfin;
          protocol = "tcp";
          bind = "lan";
          owner = "jellyfin";
          externallyBound = true;
        };
        jellyfin-discovery = {
          port = ports.jellyfinDiscovery;
          protocol = "udp";
          bind = "lan";
          owner = "jellyfin";
          externallyBound = true;
        };
      };

      caddy.virtualHosts."${vars.jellyfinDomain}" = {
        owner = "jellyfin";
        extraConfig = ''
          reverse_proxy http://${loopback}:${toString ports.jellyfin} {
            header_up X-Forwarded-Proto https
          }
        '';
      };

      dns.privateHosts."${vars.jellyfinDomain}" = {
        owner = "jellyfin";
        target = "private";
      };

      firewall.interfacePorts = [
        {
          owner = "jellyfin";
          interface = lanIface;
          protocol = "tcp";
          port = ports.jellyfin;
        }
        {
          owner = "jellyfin";
          interface = lanIface;
          protocol = "udp";
          port = ports.jellyfinDiscovery;
        }
      ];
    };
  };
}
