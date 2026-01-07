{ lib, config, vars, ... }:

{
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
        # Publicly reachable endpoint for Copyparty file links.
        # All other services are reachable only via NetBird or the LAN.
        "fileshare.${vars.domain}" = "http://127.0.0.1:${toString vars.oauth2ProxyPort}";
      };
      default = "http_status:404";
    };
  };
  # Cloudflared only makes outbound connections → no firewall ports needed

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}".serviceConfig.AppArmorProfile =
    "generated-cloudflared-tunnel-${vars.cloudflareTunnelName}";
}
