{ config, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  kanidmAccountPolicyPath = with pkgs; [
    kanidm_1_9
  ];
in
{
  systemd.services.kanidm-account-policy = {
    description = "Apply Kanidm account policy defaults";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    path = kanidmAccountPolicyPath;
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
      export KANIDM_PASSWORD

      kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      kanidm group account-policy auth-expiry \
        -H ${kanidmCliUrl} \
        -D idm_admin \
        idm_all_persons \
        ${toString vars.kanidmAuthSessionExpirySeconds}

      kanidm group account-policy privilege-expiry \
        -H ${kanidmCliUrl} \
        -D idm_admin \
        idm_all_persons \
        ${toString vars.kanidmPrivilegeSessionExpirySeconds}
    '';
    serviceConfig.Type = "oneshot";
  };
}
