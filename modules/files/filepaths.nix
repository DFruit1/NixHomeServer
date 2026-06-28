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
    ];
  };
}
