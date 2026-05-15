{ config, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  kanidmBrandingPath = with pkgs; [
    kanidm_1_9
  ];
in
{
  systemd.services.kanidm-branding = {
    description = "Apply Kanidm portal branding";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    path = kanidmBrandingPath;
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"
      export KANIDM_PASSWORD

      kanidm login \
        -H ${kanidmCliUrl} \
        -D admin >/dev/null

      kanidm system domain set-displayname \
        -H ${kanidmCliUrl} \
        -D admin \
        "Sydney Basin Services"

      kanidm system domain set-image \
        -H ${kanidmCliUrl} \
        -D admin \
        ${./assets/portal.svg} \
        svg
    '';
    serviceConfig.Type = "oneshot";
  };
}
