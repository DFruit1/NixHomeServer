{ config, lib, vars, ... }:

let
  managedDir = "${config.repo.files.paths.stateDir}/.nixos-managed";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
in
{
  options.repo.files.paths.stateDir = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/filestash";
    description = "Filestash state directory.";
  };

  config = {
    repo.storage.userRoots = {
      contentSubdirs = [ "_Files" ];
      memberGroups = [
        webAccessGroup
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ "_Files" ];

    systemd.tmpfiles.rules = [
      "d ${managedDir} 0750 root filestash -"
    ];
  };
}
