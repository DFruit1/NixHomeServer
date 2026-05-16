{ lib, config, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  httpsPort = vars.networking.ports.https;
  apps = config.nixhomeserver.apps;
in
{
  # The Cloudflare tunnel is intentionally limited to public or
  # authentication-gated endpoints. LAN/NetBird still provide the direct path
  # for private DNS resolution and local access.
  users.users.cloudflared = {
    isSystemUser = true;
    group = "cloudflared";
    home = "/var/lib/cloudflared";
  };

  users.groups.cloudflared = { };

  services.cloudflared = {
    enable = true;

    tunnels.${vars.cloudflareTunnelName} = {
      ###############  required  ######################################
      credentialsFile = config.age.secrets.cfHomeCreds.path;

      ingress =
        {
          "${vars.kanidmDomain}" = {
            service = "https://${loopback}:${toString httpsPort}";
            originRequest.originServerName = vars.kanidmDomain;
          };
        }
        // lib.optionalAttrs apps.copyparty.enable {
          "${vars.uploadsDomain}" = {
            service = "https://${loopback}:${toString httpsPort}";
            originRequest.originServerName = vars.uploadsDomain;
          };
        }
        // lib.optionalAttrs apps.immich.enable {
          "${vars.sharePhotosDomain}" = {
            service = "https://${loopback}:${toString httpsPort}";
            originRequest.originServerName = vars.sharePhotosDomain;
          };
        };
      default = "http_status:404";
    };
  };

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}" = {
    wants = [ "network-online.target" "unbound.service" ];
    after = [ "network-online.target" "unbound.service" ];
  };

  # Cloudflared only makes outbound connections → no firewall ports needed
}
