{ lib, config, vars, ... }:

{
  # The Cloudflare tunnel is intentionally limited to the public endpoints.
  # Internal apps stay on LAN/NetBird behind local DNS and Caddy.
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
        "${vars.kanidmDomain}" = "http://127.0.0.1:80";
        "fileshare.${vars.domain}" = "http://127.0.0.1:80";
      };
      default = "http_status:404";
    };
  };
  # Cloudflared only makes outbound connections → no firewall ports needed

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}".serviceConfig.AppArmorProfile =
    "generated-cloudflared-tunnel-${vars.cloudflareTunnelName}";
}
