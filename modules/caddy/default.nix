{ lib, pkgs, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
in
{
  services.caddy = {
    enable = true;

    ## Caddy will register this e-mail with Let’s Encrypt
    email  = "${vars.email}";

    ## Optional: in case you later need a global block (rate limits, DNS-01, …)
    # globalConfig = ''
    #   {
    #     # acme_dns cloudflare CF_API_TOKEN
    #   }
    # '';

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
          reverse_proxy http://127.0.0.1:${toString vars.kanidmPort} {
            header_up X-Forwarded-Proto https
            header_up X-Forwarded-Host  {host}
          }
        '';
      };

      "nextcloud.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.nextcloudPort}
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

      "vault.${vars.domain}" = {
        extraConfig = ''
          reverse_proxy http://127.0.0.1:${toString vars.vaultwardenPort}
        '';
      };
    };
  };

  ## HTTP-01 challenge & HTTPS traffic
  networking.firewall.allowedTCPPorts = [ 80 443 ];
}
