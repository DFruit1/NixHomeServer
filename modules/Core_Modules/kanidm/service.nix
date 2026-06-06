{ pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kanidmPort = vars.networking.ports.kanidm;
in
{
  services.kanidm = {
    server.enable = true;
    client.enable = true;
    client.settings.uri = vars.kanidmBaseUrl;
    package = pkgs.kanidmWithSecretProvisioning_1_10;

    server.settings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "${loopback}:${toString kanidmPort}";

      tls_chain = "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";
      tls_key = "/var/lib/acme/${vars.kanidmDomain}/key.pem";
    };
  };

  systemd.services.kanidm = {
    after = [
      "caddy.service"
      "acme-${vars.kanidmDomain}.service"
    ];
    wants = [
      "caddy.service"
      "acme-${vars.kanidmDomain}.service"
    ];
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];
}
