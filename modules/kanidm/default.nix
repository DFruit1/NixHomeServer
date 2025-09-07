{ lib, config, pkgs, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
in
{
  services.kanidm = {
    enableServer = true;
    package      = pkgs.kanidmWithSecretProvisioning;

    serverSettings = {
      origin      = "https://${vars.kanidmDomain}";
      domain      = vars.domain;
      bindaddress = "127.0.0.1:${toString vars.kanidmPort}";

      # ← NEW: reuse Caddy’s ACME files
      tls_chain   =
        "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${vars.kanidmDomain}/${vars.kanidmDomain}.crt";
      tls_key     =
        "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${vars.kanidmDomain}/${vars.kanidmDomain}.key";
    };

    provision = {
      enable               = true;
      idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
      adminPasswordFile    = config.age.secrets.kanidmSysAdminPass.path;
      instanceUrl          = "https://${vars.kanidmDomain}";
    };
  };

  networking.firewall.allowedTCPPorts = [ vars.kanidmPort ];
}
