{ config, lib, vars, ... }:

let
  userBookWritablePaths = map (name: "books/${name}") vars.userBooksSubdirs;
  userVideoWritablePaths = map (name: "videos/${name}") vars.userVideoSubdirs;
in
{
  config = lib.mkMerge [
    {
      repo.apps.files.filepaths = {
        state = vars.filesStateDir;
        cache = "/var/cache/filestash";
        userRoots.personal = vars.usersRoot;
        sharedRoots.shared = vars.sharedRoot;
        sharedRoots.quarantine = vars.uploadSecurity.quarantineRoot;
      };
    }
    (lib.mkIf config.nixhomeserver.apps.files.enable {
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
    })
  ];
}
