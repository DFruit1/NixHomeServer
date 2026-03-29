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
    package = pkgs.kanidmWithSecretProvisioning_1_9;

    serverSettings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "127.0.0.1:${toString vars.kanidmPort}";

      # reuse certificates obtained by Caddy
      tls_chain =
        "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";
      tls_key =
        "/var/lib/acme/${vars.kanidmDomain}/key.pem";
    };

    provision = {
      enable = true;
      idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
      adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
      instanceUrl = "https://${vars.kanidmDomain}";
      acceptInvalidCerts = true;

      groups.fileshare_users = { };

      systems.oauth2.oauth2-proxy = {
        displayName = "OAuth2 Proxy";
        originUrl = "https://fileshare.${vars.domain}/oauth2/callback";
        originLanding = "https://fileshare.${vars.domain}";
        basicSecretFile = config.age.secrets.oauth2ProxyClientSecret.path;
        scopeMaps.fileshare_users = [ "openid" "profile" "email" "groups" ];
      };
    };
  };

  systemd.services.kanidm = {
    after = [ "caddy.service" "acme-${vars.kanidmDomain}.service" ];
    wants = [ "caddy.service" "acme-${vars.kanidmDomain}.service" ];
    serviceConfig.AppArmorProfile = "generated-kanidm";
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];
}
