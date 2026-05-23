{ vars, ... }:

let
  userBookWritablePaths = map (name: "books/${name}") vars.userBooksSubdirs;
  userVideoWritablePaths = map (name: "videos/${name}") vars.userVideoSubdirs;
  managedDir = "${vars.filesStateDir}/.nixos-managed";
in
{
  config = {
    repo.storage.userRoots = {
      memberGroups = [
        "user-files"
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

    systemd.tmpfiles.rules = [
      "d ${managedDir} 0750 root filestash -"
    ];
  };
}
