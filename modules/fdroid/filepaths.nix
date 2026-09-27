{ config, lib, ... }:

{
  options.repo.fdroid.paths = {
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/fdroidserver";
      description = "Persistent F-Droid repository metadata, APKs, and index signing key.";
    };
  };

  options.repo.fdroid.publisher = lib.mkOption {
    type = lib.types.str;
    readOnly = true;
    default = "/run/current-system/sw/bin/fdroid-publish";
    description = "Command used by gated integrations to add signed APKs to the repository.";
  };

  options.repo.fdroid.mirrorUrls = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = "Additional base URLs for the signed F-Droid repository.";
  };

  config.systemd.tmpfiles.rules = [
    "d ${config.repo.fdroid.paths.stateDir} 0755 fdroidserver fdroidserver -"
    "d ${config.repo.fdroid.paths.stateDir}/repo 0755 fdroidserver fdroidserver -"
    "d ${config.repo.fdroid.paths.stateDir}/metadata 0755 fdroidserver fdroidserver -"
  ];
}
