{ config, lib, pkgs, vars, ... }:

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
      systemd.tmpfiles.rules = [
        "d ${cfg.dataDir} 0750 mail-archive-ui mail-archive-ui -"
        "d ${cfg.accountStateRoot} 0750 mail-archive-ui mail-archive-ui -"
        "d ${cfg.runtimeDir} 0750 mail-archive-ui mail-archive-ui -"
        "d ${cfg.lockDir} 0750 mail-archive-ui mail-archive-ui -"
      ];

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

      systemd.services.mail-archive-ui-storage-layout-v1 = {
        description = "Provision Mail Archive UI storage layout";
        wantedBy = [ "multi-user.target" ];
        wants = [ "data-pool-layout.service" "local-fs.target" ];
        after = [ "data-pool-layout.service" "local-fs.target" ];
        before = [ "mail-archive-ui.service" ];
        unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        path = [
          pkgs.acl
          pkgs.coreutils
        ];
        script = ''
          set -euo pipefail

          install -d -m 0770 -o mail-archive-ui -g mail-archive-ui '${vars.sharedEmailsRoot}'
          setfacl -m 'g:mail-archive-ui:--x' '${vars.sharedRoot}'
        '';
      };

      systemd.services.mail-archive-ui = {
        wants = [ "mail-archive-ui-storage-layout-v1.service" ];
        after = [ "mail-archive-ui-storage-layout-v1.service" ];
      };
    })
  ];
}
