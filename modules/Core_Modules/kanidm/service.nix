{ config, lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  oauth2ClientsForConsentPrompt = lib.filterAttrs
    (_name: client: (client.present or true) && !(client.public or false))
    config.services.kanidm.provision.systems.oauth2;
  disableConsentCommands = lib.concatStringsSep "\n"
    (map (clientName: ''
      ${pkgs.kanidm_1_10}/bin/kanidm system oauth2 disable-consent-prompt \
        -H ${kanidmCliUrl} \
        -D idm_admin \
        ${lib.escapeShellArg clientName}
    '')
      (builtins.attrNames oauth2ClientsForConsentPrompt));
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

  systemd.services.kanidm-disable-consent-prompt = lib.mkIf (oauth2ClientsForConsentPrompt != { }) {
    description = "Disable Kanidm consent prompt for configured OAuth2 clients";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "10s";
    };
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
      export KANIDM_PASSWORD

      ${pkgs.kanidm_1_10}/bin/kanidm login -H ${kanidmCliUrl} -D idm_admin >/dev/null

      ${disableConsentCommands}
    '';
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];
}
