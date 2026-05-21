{ config, lib, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
in
{
  config = lib.mkIf config.nixhomeserver.apps.copyparty.enable {
    repo.networking = {
      ports = {
        copyparty = {
          port = vars.networking.ports.copyparty;
          protocol = "tcp";
          bind = "loopback";
          owner = "copyparty";
        };
        oauth2-proxy-uploads = {
          port = vars.networking.ports.oauth2ProxyUploads;
          protocol = "tcp";
          bind = "loopback";
          owner = "copyparty";
        };
      };

      caddy.virtualHosts."${vars.uploadsDomain}" = {
        owner = "copyparty";
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

      cloudflare.ingress."${vars.uploadsDomain}" = {
        owner = "copyparty";
        service = "https://${loopback}:${toString httpsPort}";
        originServerName = vars.uploadsDomain;
      };

      dns.privateHosts."${vars.uploadsDomain}" = {
        owner = "copyparty";
        target = "lan";
        publishOnLan = true;
        publishOnNetbird = false;
      };
    };
  };
}
