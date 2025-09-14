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
        "${vars.domain}" = "https://localhost";
        "www.${vars.domain}" = "https://localhost";
        "${vars.kanidmDomain}" = "https://localhost";
        "paperless.${vars.domain}" = "https://localhost";
        "audiobookshelf.${vars.domain}" = "https://localhost";
        "fileshare.${vars.domain}" = "https://localhost";
        "photoshare.${vars.domain}" = "https://localhost";
        "vault.${vars.domain}" = "https://localhost";
      };
      default = "http_status:404";
    };
  };
  # Cloudflared only makes outbound connections → no firewall ports needed
}
