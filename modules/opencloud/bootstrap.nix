{ config, lib, pkgs, ... }:

let
  cfg = config.repo.opencloud;
  stateDir = cfg.paths.stateDir;
  adminEnvFile = "${stateDir}/config/opencloud-admin.env";
in
{
  # The built-in IDM admin credential is needed to seed the internal LDAP
  # directory on first init. Generate it once on disk rather than shipping a
  # default password in the world-readable Nix store.
  systemd.services.opencloud-secret-materialize = {
    description = "Materialize the OpenCloud built-in admin credential";
    wantedBy = [ "multi-user.target" ];
    before = [
      "opencloud-init-config.service"
      "opencloud.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [ pkgs.coreutils pkgs.openssl ];
    script = ''
      set -euo pipefail

      install -d -m 0750 -o opencloud -g opencloud ${lib.escapeShellArg "${stateDir}/config"}
      if [ ! -s ${lib.escapeShellArg adminEnvFile} ]; then
        umask 0077
        printf 'IDM_ADMIN_PASSWORD=%s\n' "$(openssl rand -base64 24 | tr -d '\n')" > ${lib.escapeShellArg adminEnvFile}
      fi
      chown opencloud:opencloud ${lib.escapeShellArg adminEnvFile}
      chmod 0600 ${lib.escapeShellArg adminEnvFile}
    '';
  };
}
