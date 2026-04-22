{ config, pkgs, vars, ... }:

let
  kanidmPort = 8443;
in
{
  systemd.services.kanidm-account-policy = {
    description = "Apply Kanidm account policy defaults";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    path = [ pkgs.kanidm_1_9 ];
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"

      kanidm login \
        -H https://localhost:${toString kanidmPort} \
        -D idm_admin \
        --accept-invalid-certs >/dev/null

      kanidm group account-policy auth-expiry \
        -H https://localhost:${toString kanidmPort} \
        -D idm_admin \
        --accept-invalid-certs \
        idm_all_persons \
        ${toString vars.kanidmAuthSessionExpirySeconds}
    '';
    serviceConfig.Type = "oneshot";
  };
}
