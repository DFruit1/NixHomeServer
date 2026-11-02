{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.storage.desktopBackups;
  user = vars.localAdminUser;
  folder = "Desktop-${user}";
  backupRoot = vars.backupRoot or "${vars.dataRoot}/backups";
  source = "${backupRoot}/${folder}";
  targets = [
    "${vars.usersRoot}/${user}/_Backups/${folder}"
    "${vars.fileAccess.sftpChrootBase}/${user}/_Backups/${folder}"
    "${vars.fileAccess.sftpChrootBase}/${user}@${vars.domain}/_Backups/${folder}"
  ];
  parents = [
    "files-backups-bindfs@${user}.service"
    "files-sftp-user-root@${user}.service"
  ];
in
{
  options.repo.storage.desktopBackups.enable = lib.mkEnableOption
    "an owner-writable desktop backup folder inside the read-only backup view";

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = builtins.elem user (vars.filesSftpUsers or [ ]);
      message = "Desktop backups require the local administrator's Files SFTP bridge.";
    }];

    systemd.services.desktop-backup-upload = {
      description = "Expose the owner's writable desktop backup folder";
      wantedBy = [ "multi-user.target" ];
      requires = parents;
      after = parents;
      partOf = parents;
      path = with pkgs; [ acl coreutils util-linux ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      script = ''
        set -euo pipefail
        mountpoint -q ${lib.escapeShellArg backupRoot}
        source=${lib.escapeShellArg source}
        test ! -L "$source"
        install -d -m 0700 -o ${lib.escapeShellArg user} -g root "$source"
        # Remove inherited reader ACLs on this folder only. Existing server
        # backup repositories and the parent read-only bindfs remain intact.
        setfacl -b -k "$source"
        for target in ${lib.escapeShellArgs targets}; do
          mountpoint -q "$(dirname "$target")"
          test -d "$target"
          test ! -L "$target"
          if mountpoint -q "$target"; then
            test "$(stat -c %d:%i "$source")" = "$(stat -c %d:%i "$target")"
          else
            mount --bind "$source" "$target"
          fi
        done
      '';
      preStop = ''
        set -euo pipefail
        for target in ${lib.escapeShellArgs (lib.reverseList targets)}; do
          if mountpoint -q "$target"; then
            test "$(stat -c %d:%i ${lib.escapeShellArg source})" = "$(stat -c %d:%i "$target")"
            umount "$target"
          fi
        done
      '';
    };
  };
}
