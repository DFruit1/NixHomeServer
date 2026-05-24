{ pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kanidmPort = vars.networking.ports.kanidm;
in
{
  services.kanidm = {
    enableServer = true;
    enableClient = true;
    clientSettings.uri = vars.kanidmBaseUrl;
    package = pkgs.kanidmWithSecretProvisioning_1_9;

    serverSettings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "${loopback}:${toString kanidmPort}";

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
