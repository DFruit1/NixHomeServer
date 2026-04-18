{ config, lib, pkgs, vars, ... }:

let
  backupTimer = "*-*-* 20:30:00";
  backupPruneTimer = "Sat *-*-* 21:00:00";
  backupStatePaths = [
    "/var/lib/kanidm"
    "/var/lib/acme"
    "/var/lib/snapraid"
    "/etc/ssh"
    vars.appdataRoot
  ];
  backupCriticalDataPaths = [ ];
  backupStateExcludes = [
    "${vars.appdataRoot}/**/cache"
    "${vars.appdataRoot}/**/log"
    "${vars.appdataRoot}/**/logs"
  ];
  backupPrepareCommand =
    if vars.enableBackupDisk then
      ''
        set -euo pipefail

        if ! ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg vars.backupMountPoint}; then
          echo "Backup disk is not mounted at ${vars.backupMountPoint}" >&2
          exit 1
        fi

        ${pkgs.coreutils}/bin/install -d -m 0700 ${lib.escapeShellArg vars.backupRepository}
      ''
    else
      ''
        echo "Backup disk scaffold is disabled; refusing to run backups until enableBackupDisk = true." >&2
        exit 1
      '';
in
lib.mkIf vars.enableBackups {
  assertions = [
    {
      assertion = !vars.enableBackupDisk || vars.backupDisk != null;
      message = "vars.enableBackupDisk requires vars.backupDisk to be set to a stable /dev/disk/by-id entry.";
    }
    {
      assertion =
        let
          protectedRoots = backupStatePaths ++ backupCriticalDataPaths;
        in
          !(lib.any (path: path == vars.mediaDataRoot || path == vars.workspaceDataRoot) protectedRoots);
      message = "Backups must not include vars.mediaDataRoot or vars.workspaceDataRoot in this phase.";
    }
  ];

  environment.systemPackages = [ pkgs.restic ];

  systemd.tmpfiles.rules = [
    "d ${vars.backupMountPoint} 0750 root root -"
  ];

  services.restic.backups = {
    "server-state" = {
      paths = backupStatePaths ++ backupCriticalDataPaths;
      exclude = backupStateExcludes;
      repository = vars.backupRepository;
      passwordFile = config.age.secrets.resticPassword.path;
      initialize = true;
      backupPrepareCommand = backupPrepareCommand;
      timerConfig =
        if vars.enableBackupDisk then
          {
            OnCalendar = backupTimer;
            Persistent = true;
          }
        else
          null;
    };

    "server-state-prune" = {
      repository = vars.backupRepository;
      passwordFile = config.age.secrets.resticPassword.path;
      backupPrepareCommand = backupPrepareCommand;
      pruneOpts = [
        "--keep-daily 14"
        "--keep-weekly 8"
        "--keep-monthly 6"
      ];
      timerConfig =
        if vars.enableBackupDisk then
          {
            OnCalendar = backupPruneTimer;
            Persistent = true;
          }
        else
          null;
    };
  };
}
