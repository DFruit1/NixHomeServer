{ lib, pkgs, vars, config, ... }:

{
  services.caddy = {
    enable = true;


    ## Caddy will register this e-mail with Let’s Encrypt
    email = "${vars.email}";

    ## Use Cloudflare DNS-01 challenge for all certificates
    globalConfig = ''
      {
        acme_dns cloudflare {env.CF_API_TOKEN}
        email ${vars.email}
      }
    '';

    virtualHosts = {
      "${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.homepagePort}
        '';
      };

      "www.${vars.domain}" = {
        extraConfig = ''
          redir https://${vars.domain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem
          reverse_proxy http://127.0.0.1:${toString vars.kanidmPort} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host  {host}
          }
        '';
      };

      "immich.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.immichPort}
        '';
      };

      "paperless.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.paperlessPort}
        '';
      };

      "audiobookshelf.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.audiobookshelfPort}
        '';
      };

      "fileshare.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.oauth2ProxyPort}
        '';
      };

      "photoshare.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.immichPort}
        '';
      };

      "vault.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.vaultwardenPort}
        '';
      };
    };
  };

  systemd.services.caddy.serviceConfig.EnvironmentFile = config.age.secrets.cfAPIToken.path;

  ## HTTP-01 challenge & HTTPS traffic
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}