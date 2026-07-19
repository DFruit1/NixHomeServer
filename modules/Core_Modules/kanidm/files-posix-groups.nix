{ config, lib, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  fileAccessPosixGroups = lib.mapAttrsToList
    (name: gid: {
      inherit name gid;
    })
    vars.fileAccessPosixGids;
  fileAccessPosixUsers = lib.unique (
    [ vars.kanidmAdminUser ]
    ++ (vars.filesSftpUsers or [ ])
    ++ (vars.kanidmAppUsers or [ ])
    ++ (vars.kanidmBackupUsers or [ ])
    ++ (vars.fileAccess.usbUsers or [ ])
  );
  kanidmFilesPosixGroupsPath = with pkgs; [
    coreutils
    gnugrep
    kanidm_1_10
  ];
  retiredPosixGroups = {
    user-files = vars.fileAccessPosixGids.${vars.fileAccess.webAccessGroup};
    admin-backups = vars.fileAccessPosixGids.${vars.backupAccess.storageGroup};
  };
in
{
  systemd.services.kanidm-files-posix-groups = {
    description = "Converge Kanidm file-access POSIX groups and SSH keys";
    wantedBy = [ "multi-user.target" ];
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    before = [
      "fileshare-user-root-sync.service"
    ];
    path = kanidmFilesPosixGroupsPath;
    script = ''
      set -euo pipefail

      export HOME="$(mktemp -d)"
      trap 'rm -rf "$HOME"' EXIT
      KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
      export KANIDM_PASSWORD

      kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      reset_retired_posix_group_gid() {
        local group_name="$1"
        local gid="$2"
        local group_details

        if ! group_details="$(
          kanidm group get \
            "$group_name" \
            -H ${kanidmCliUrl} \
            -D idm_admin
        )"; then
          return 0
        fi

        if printf '%s\n' "$group_details" | grep -qx "gidnumber: $gid"; then
          kanidm group posix reset-gidnumber \
            "$group_name" \
            -H ${kanidmCliUrl} \
            -D idm_admin >/dev/null
        fi
      }

      ensure_posix_group() {
        local group_name="$1"
        local gid="$2"

        kanidm group get \
          "$group_name" \
          -H ${kanidmCliUrl} \
          -D idm_admin >/dev/null

        kanidm group posix set \
          "$group_name" \
          --gidnumber "$gid" \
          -H ${kanidmCliUrl} \
          -D idm_admin >/dev/null
      }

      ensure_posix_account() {
        local username="$1"

        kanidm person posix set \
          "$username" \
          --shell ${lib.escapeShellArg "${pkgs.bashInteractive}/bin/bash"} \
          -H ${kanidmCliUrl} \
          -D idm_admin >/dev/null
      }

      ${lib.concatMapStringsSep "\n      " (groupName: ''
        reset_retired_posix_group_gid ${lib.escapeShellArg groupName} ${lib.escapeShellArg (toString retiredPosixGroups.${groupName})}
      '') (builtins.attrNames retiredPosixGroups)}
      ${lib.concatMapStringsSep "\n      " (group: ''
        ensure_posix_group ${lib.escapeShellArg group.name} ${lib.escapeShellArg (toString group.gid)}
      '') fileAccessPosixGroups}
      ${lib.concatMapStringsSep "\n      " (username: ''
        ensure_posix_account ${lib.escapeShellArg username}
      '') fileAccessPosixUsers}
    '';
    serviceConfig = {
      Type = "oneshot";
      Restart = "on-failure";
      RestartSec = "30s";
    };
  };
}
