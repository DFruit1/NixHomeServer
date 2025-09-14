{ lib, config, pkgs, vars, ... }:

{
  assertions = [
    {
      assertion = config.age.secrets ? kanidmAdminPass;
      message = "Missing kanidmAdminPass secret; run scripts/gen-all-secrets.sh";
    }
    {
      assertion = config.age.secrets ? kanidmSysAdminPass;
      message = "Missing kanidmSysAdminPass secret; run scripts/gen-all-secrets.sh";
    }
  ];

  services.kanidm = {
    enableServer = true;
    package = pkgs.kanidmWithSecretProvisioning;

    serverSettings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "127.0.0.1:${toString vars.kanidmPort}";

      # reuse certificates obtained by Caddy
      tls_chain =
        "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${vars.kanidmDomain}/${vars.kanidmDomain}.crt";
      tls_key =
        "/var/lib/caddy/.local/share/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${vars.kanidmDomain}/${vars.kanidmDomain}.key";
    };

    provision = {
      enable = true;
      idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
      adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
      instanceUrl = "https://${vars.kanidmDomain}";
    };
  };

  systemd.services.kanidm = {
    after = [ "caddy.service" "acme-${vars.kanidmDomain}.service" ];
    wants = [ "caddy.service" "acme-${vars.kanidmDomain}.service" ];
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];

  networking.firewall.allowedTCPPorts = [ vars.kanidmPort ];
}
