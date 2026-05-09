{ config, pkgs, vars, ... }:

let
  kanidmPort = 8443;
in
{
  assertions = [
    {
      assertion = config.age.secrets ? kanidmAdminPass;
      message = "Missing kanidmAdminPass secret; run scripts/generate-all-secrets.sh";
    }
    {
      assertion = config.age.secrets ? kanidmSysAdminPass;
      message = "Missing kanidmSysAdminPass secret; run scripts/generate-all-secrets.sh";
    }
  ];

  services.kanidm = {
    enableServer = true;
    enableClient = true;
    clientSettings.uri = vars.kanidmBaseUrl;
    package = pkgs.kanidmWithSecretProvisioning_1_9;

    serverSettings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "127.0.0.1:${toString kanidmPort}";

      tls_chain = "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";
      tls_key = "/var/lib/acme/${vars.kanidmDomain}/key.pem";
    };
  };

  systemd.services.kanidm = {
    after = [
      "oauth2-proxy-secret-materialize.service"
      "caddy.service"
      "acme-${vars.kanidmDomain}.service"
    ];
    wants = [
      "oauth2-proxy-secret-materialize.service"
      "caddy.service"
      "acme-${vars.kanidmDomain}.service"
    ];
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];
}
