{ config, lib, vars, ... }:

let
  userBookWritablePaths = map (name: "books/${name}") config.repo.storage.userRoots.bookSubdirs;
  userVideoWritablePaths = map (name: "videos/${name}") config.repo.storage.userRoots.videoSubdirs;
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
      contentSubdirs = [ "files" ];
      memberGroups = [
        webAccessGroup
      ];
      recursiveWritableGrants = [
        {
          group = "filestash";
          relativePaths = [
            "uploads"
            "files"
            "documents"
            "photos"
            "audiobooks"
            "videos"
            "books"
          ] ++ userVideoWritablePaths ++ userBookWritablePaths;
        }
      ];
      recursiveReadonlyGrants = [
        {
          group = "filestash";
          relativePaths = [ "emails" ];
        }
      ];
      recursiveDirectoryNoAccessGrants = [
        {
          group = "filestash";
          relativePaths = [ "emails/.internal-sync" ];
        }
      ];
    };

    repo.storage.sharedRoots.contentSubdirs = [ "files" ];

    systemd.tmpfiles.rules = [
      "d ${managedDir} 0750 root filestash -"
    ];
  };
}
