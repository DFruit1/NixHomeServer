{ config, lib, vars, ... }:

let
  userBookWritablePaths = map (name: "books/${name}") vars.userBooksSubdirs;
in
{
  config = lib.mkMerge [
    {
      repo.apps.kavita.filepaths = {
        state = "/var/lib/kavita";
        sharedRoots.books = vars.sharedBooksRoot;
        userRoots.personal = vars.usersRoot;
      };
    }
    (lib.mkIf config.nixhomeserver.apps.kavita.enable {
      repo.storage.userRoots = {
        rootTraverseGroups = [
          "kavita-media"
        ];
        recursiveWritableGrants = [
          {
            group = "kavita-media";
            relativePaths = [ "books" ] ++ userBookWritablePaths;
          }
        ];
      };
    })
  ];
}
