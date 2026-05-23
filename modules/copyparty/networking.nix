{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
  host = "uploads.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      @edge_http header X-Forwarded-Proto http
      redir @edge_http https://{host}{uri} 308
      reverse_proxy http://${config.services.oauth2-proxy.httpAddress} {
        header_up X-Forwarded-Proto https
        header_up X-Forwarded-Host {host}
        header_up X-Forwarded-For {http.request.header.Cf-Connecting-Ip}
        header_up Cf-Connecting-Ip {http.request.header.Cf-Connecting-Ip}
      }
    '';
  };

  services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress.${host} = {
    service = "https://${loopback}:${toString httpsPort}";
    originRequest.originServerName = host;
  };

  services.unbound.privateHosts.${host} = {
    target = "lan";
    publishOnLan = true;
    publishOnNetbird = false;
  };
}
