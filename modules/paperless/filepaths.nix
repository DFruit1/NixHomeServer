{ pkgs, vars, ... }:

{
  config = {
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

    systemd.services.paperless-storage-layout-v1 = {
      description = "Provision Paperless storage layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [
        "paperless-consumer.service"
        "paperless-scheduler.service"
        "paperless-task-queue.service"
        "paperless-web.service"
      ];
      path = [
        pkgs.acl
        pkgs.coreutils
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        inbox_dir='${vars.paperlessInboxRoot}'
        handoff_staging_dir='${vars.paperlessHandoffStagingRoot}'
        archive_dir='${vars.paperlessArchiveRoot}'
        export_dir='${vars.paperlessExportRoot}'

        install -d -m 0755 -o root -g root '${vars.paperlessRoot}'
        install -d -m 2770 -o root -g paperless "$inbox_dir"
        install -d -m 2770 -o root -g paperless "$handoff_staging_dir"
        install -d -m 0750 -o paperless -g paperless "$archive_dir"
        install -d -m 0750 -o paperless -g paperless "$export_dir"
      '';
    };
  };
}
