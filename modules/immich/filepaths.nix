{ config, lib, vars, ... }:

{
  config = lib.mkMerge [
    {
      repo.apps.immich.filepaths = {
        state = "/var/lib/immich";
        cache = "/var/cache/immich";
        data = vars.immichRoot;
        mediaRoots.managed = vars.immichManagedRoot;
        mediaRoots.external = vars.immichExternalRoot;
        userRoots.photos = "${vars.usersRoot}/<user>/photos";
      };
    }
    (lib.mkIf config.nixhomeserver.apps.immich.enable {
      repo.storage.userRoots = {
        rootTraverseGroups = [
          "immich"
        ];
        recursiveReadonlyGrants = [
          {
            group = "immich";
            relativePaths = [ "photos" ];
          }
        ];
      };
    })
  ];
}
