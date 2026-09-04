{ config, lib, vars, ... }:

let
  archiveCfg = config.repo.files.archives;
  managedDir = "${config.repo.files.paths.stateDir}/.nixos-managed";
  webAccessGroup = vars.fileAccess.webAccessGroup or "files-personal-users";
in
{
  options.repo.files.paths.stateDir = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/filestash";
    description = "Filestash state directory.";
  };

  config = {
    repo.storage.userRoots = {
      contentSubdirs = [ "_Files" ] ++ lib.optional archiveCfg.enable archiveCfg.directoryName;
      memberGroups = [
        webAccessGroup
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ "_Files" ] ++ lib.optional archiveCfg.enable archiveCfg.directoryName;

    systemd.tmpfiles.rules = [
      "d ${managedDir} 0750 root filestash -"
      "d /var/log/filestash 0750 filestash filestash 14d"
    ];

    # Filestash's persisted log directory grows without app-managed limits,
    # so bound it here: daily rotation with a per-file size trigger, four
    # compressed rotations, and tmpfiles aging for anything else left behind.
    services.logrotate.settings.filestash-logs = {
      files = [ "/var/log/filestash/*.log" ];
      frequency = "daily";
      maxsize = "20M";
      rotate = 4;
      compress = true;
      copytruncate = true;
    };
  };
}
