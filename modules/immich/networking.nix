{ config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
  photosHost = "photos.${vars.domain}";
  shareHost = "sharephotos.${vars.domain}";
in
{
  assertions = [
    {
      assertion = photosHost != shareHost;
      message = "immich: private and public share hostnames must be distinct.";
    }
  ];

  services.caddy.virtualHosts = {
    ${photosHost} = {
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString config.services.immich.port}
      '';
    };
    ${shareHost} = {
      useACMEHost = vars.domain;
      extraConfig = ''
        reverse_proxy http://${loopback}:${toString vars.networking.ports.immichPublicProxy} {
          header_up X-Forwarded-Proto https
          header_up X-Forwarded-Host {host}
        }
      '';
    };
  };

  services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress.${shareHost} = {
    service = "https://${loopback}:${toString httpsPort}";
    originRequest.originServerName = shareHost;
  };

  services.unbound.privateHosts = {
    ${photosHost} = {
      target = "private";
    };
    ${shareHost} = {
      target = "private";
    };
  };
}
