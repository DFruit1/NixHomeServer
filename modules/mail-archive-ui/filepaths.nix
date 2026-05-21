{ config, lib, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
in
{
  config = lib.mkMerge [
    {
      repo.apps."mail-archive-ui".filepaths = {
        state = cfg.dataDir;
        data = cfg.storeRoot;
        runtime.main = cfg.runtimeDir;
        runtime.locks = cfg.lockDir;
        userRoots.mailStore = cfg.storeRoot;
        sharedRoots.emails = vars.sharedEmailsRoot;
        mediaRoots.accountState = cfg.accountStateRoot;
      };
    }
    (lib.mkIf cfg.enable {
      repo.storage.userRoots = {
        perUserDirectories = [
          {
            root = vars.usersRoot;
            relativePath = "emails";
            mode = "0770";
            user = "mail-archive-ui";
            group = "mail-archive-ui";
          }
          {
            root = vars.usersRoot;
            relativePath = "emails/.internal-sync";
            mode = "0770";
            user = "mail-archive-ui";
            group = "mail-archive-ui";
          }
        ];
        rootTraverseGroups = [
          "mail-archive-ui"
        ];
        recursiveWritableGrants = [
          {
            group = "mail-archive-ui";
            relativePaths = [ "files" ];
          }
        ];
      };
    })
  ];
}
