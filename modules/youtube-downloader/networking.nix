{ vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  host = "ytdownload.${vars.domain}";
in
{
  services.caddy.virtualHosts.${host} = {
    useACMEHost = vars.domain;
    extraConfig = ''
      @legacy_service_worker path /ngsw-worker.js /custom-service-worker.js /ngsw.json
      handle @legacy_service_worker {
        header Cache-Control no-store
        respond "Legacy service worker removed" 410
      }

      handle {
        reverse_proxy http://${loopback}:${toString vars.networking.ports.oauth2ProxyDownloads} {
          header_up X-Forwarded-Proto https
          header_up X-Forwarded-Host {host}
        }
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
  };
}
