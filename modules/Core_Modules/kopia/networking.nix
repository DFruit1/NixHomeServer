{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
  host = vars.kopiaDomain;
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyKopia} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
      }
    '';
  };

  services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress.${host} = {
    service = "https://${loopback}:${toString httpsPort}";
    originRequest.originServerName = host;
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
