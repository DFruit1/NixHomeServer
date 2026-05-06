{ lib, config, vars, ... }:

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

      ingress = {
        "${vars.kanidmDomain}" = {
          service = "https://127.0.0.1:443";
          originRequest.originServerName = vars.kanidmDomain;
        };
        "${vars.uploadsDomain}" = {
          service = "https://127.0.0.1:443";
          originRequest.originServerName = vars.uploadsDomain;
        };
        "${vars.filebrowserDomain}" = {
          service = "https://127.0.0.1:443";
          originRequest.originServerName = vars.filebrowserDomain;
        };
        "${vars.sharePhotosDomain}" = {
          service = "https://127.0.0.1:443";
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
