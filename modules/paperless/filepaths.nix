{ config, lib, vars, ... }:

{
  config = lib.mkMerge [
    {
      repo.apps.paperless.filepaths = {
        state = "/var/lib/paperless";
        data = vars.paperlessRoot;
        mediaRoots.inbox = vars.paperlessInboxRoot;
        mediaRoots.archive = vars.paperlessArchiveRoot;
        mediaRoots.export = vars.paperlessExportRoot;
        mediaRoots.handoffStaging = vars.paperlessHandoffStagingRoot;
        userRoots.documents = "${vars.usersRoot}/<user>/documents";
      };
    }
    (lib.mkIf config.nixhomeserver.apps.paperless.enable {
      repo.storage.userRoots = {
        rootTraverseGroups = [
          "paperless"
        ];
        recursiveReadonlyGrants = [
          {
            group = "paperless";
            relativePaths = [ "documents" ];
          }
        ];
      };
    })
  ];
}
