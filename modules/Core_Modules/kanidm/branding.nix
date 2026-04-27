{ config, pkgs, vars, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
in
{
  systemd.services.kanidm-branding = {
    description = "Apply Kanidm portal branding";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    path = [ pkgs.kanidm_1_9 ];
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

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
