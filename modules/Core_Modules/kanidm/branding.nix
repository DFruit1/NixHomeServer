{ config, pkgs, vars, ... }:

let
  kanidmPort = 8443;
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
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs >/dev/null

      kanidm system domain set-displayname \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        "Sydney Basin Services"

      kanidm system domain set-image \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        ${./assets/portal.svg} \
        svg
    '';
    serviceConfig.Type = "oneshot";
  };
}
