{ lib, pkgs, vars, config, ... }:

{
  services.caddy = {
    enable = true;

    ## Caddy will register this e-mail with Let’s Encrypt
    email = "${vars.email}";

    virtualHosts = {
      "${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "www.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          redir https://${vars.kanidmDomain}{uri} 308
        '';
      };

      "${vars.kanidmDomain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.kanidmDomain}/fullchain.pem /var/lib/acme/${vars.kanidmDomain}/key.pem
          reverse_proxy https://127.0.0.1:${toString vars.kanidmPort} {
            transport http {
              tls_server_name ${vars.kanidmDomain}
              tls_insecure_skip_verify
            }
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host  {host}
          }
        '';
      };

      "immich.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString vars.immichPort}
        '';
      };

      "paperless.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString vars.paperlessPort}
        '';
      };

      "audiobookshelf.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString vars.audiobookshelfPort}
        '';
      };

      "fileshare.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString vars.oauth2ProxyPort}
        '';
      };

      "photoshare.${vars.domain}" = {
        extraConfig = ''
          tls /var/lib/acme/${vars.domain}/fullchain.pem /var/lib/acme/${vars.domain}/key.pem
          reverse_proxy http://127.0.0.1:${toString vars.immichPort}
        '';
      };
    };
  };

  systemd.services.caddy = {
    wants = [
      "acme-${vars.domain}.service"
      "acme-${vars.kanidmDomain}.service"
    ];
    after = [
      "acme-${vars.domain}.service"
      "acme-${vars.kanidmDomain}.service"
    ];
    serviceConfig.AppArmorProfile = "generated-caddy";
  };

  ## HTTP-01 challenge & HTTPS traffic
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
