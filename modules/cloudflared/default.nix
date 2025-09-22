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
        "${vars.domain}" = "http://127.0.0.1:${toString vars.homepagePort}";
        "www.${vars.domain}" = "http://127.0.0.1:${toString vars.homepagePort}";
        "${vars.kanidmDomain}" = {
          service = "https://127.0.0.1:${toString vars.kanidmPort}";
          originRequest = {
            originServerName = vars.kanidmDomain;
            httpHostHeader = vars.kanidmDomain;
          };
        };
        "paperless.${vars.domain}" = "http://127.0.0.1:${toString vars.paperlessPort}";
        "immich.${vars.domain}" = "http://127.0.0.1:${toString vars.immichPort}";
        "audiobookshelf.${vars.domain}" = "http://127.0.0.1:${toString vars.audiobookshelfPort}";
        "fileshare.${vars.domain}" = "http://127.0.0.1:${toString vars.oauth2ProxyPort}";
        "photoshare.${vars.domain}" = "http://127.0.0.1:${toString vars.immichPort}";
        "vault.${vars.domain}" = "http://127.0.0.1:${toString vars.vaultwardenPort}";
      };
      default = "http_status:404";
    };
  };
  # Cloudflared only makes outbound connections → no firewall ports needed

  systemd.services."cloudflared-tunnel-${vars.cloudflareTunnelName}".serviceConfig.AppArmorProfile =
    "generated-cloudflared-tunnel-${vars.cloudflareTunnelName}";
}
