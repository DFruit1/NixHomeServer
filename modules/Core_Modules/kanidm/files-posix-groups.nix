{ config, lib, pkgs, vars, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  fileAccessPosixGroups = lib.mapAttrsToList (name: gid: {
    inherit name gid;
  }) vars.fileAccessPosixGids;
in
{
  systemd.services.kanidm-files-posix-groups = {
    description = "Converge Kanidm file-access groups to fixed POSIX GIDs";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    before = [
      "fileshare-user-root-sync.service"
      "samba-smbd.service"
    ];
    path = [
      pkgs.coreutils
      pkgs.kanidm_1_9
    ];
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

      kanidm login \
        -H ${kanidmCliUrl} \
        -D admin >/dev/null

      ensure_posix_group() {
        local group_name="$1"
        local gid="$2"

        kanidm group get \
          "$group_name" \
          -H ${kanidmCliUrl} \
          -D admin >/dev/null

        kanidm group posix set \
          "$group_name" \
          --gidnumber "$gid" \
          -H ${kanidmCliUrl} \
          -D admin >/dev/null
      }

      ${lib.concatMapStringsSep "\n      " (group: ''
        ensure_posix_group ${lib.escapeShellArg group.name} ${lib.escapeShellArg (toString group.gid)}
      '') fileAccessPosixGroups}
    '';
    serviceConfig.Type = "oneshot";
  };
}
