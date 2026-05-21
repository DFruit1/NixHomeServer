{ config, lib, pkgs, vars, ... }:

{
  config = lib.mkIf config.services.mail-archive-ui.enable {
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
        setfacl \
          -m 'g:filestash:r-x' \
          -m 'd:g:filestash:r-x' \
          '${vars.sharedEmailsRoot}'
      '';
    };

    systemd.services.mail-archive-ui = {
      wants = [ "mail-archive-ui-storage-layout-v1.service" ];
      after = [ "mail-archive-ui-storage-layout-v1.service" ];
    };
  };
}
