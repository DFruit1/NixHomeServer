{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  lanIface = vars.networking.interfaces.lan;
  ports = vars.networking.ports;
  host = "videos.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString ports.jellyfin} {
        header_up X-Forwarded-Proto https
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };

  networking.firewall.interfaces.${lanIface} = {
    allowedTCPPorts = [ ports.jellyfin ];
    allowedUDPPorts = [ ports.jellyfinDiscovery ];
  };
}
