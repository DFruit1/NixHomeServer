{ lib, config, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
in
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
        "share.${vars.domain}" = "https://localhost";
        "${vars.kanidmDomain}" = "https://localhost:${toString vars.kanidmPort}";
      };
      default = "http_status:404";
    };
  };
  # Cloudflared only makes outbound connections → no firewall ports needed
}
