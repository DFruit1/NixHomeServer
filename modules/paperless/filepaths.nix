{ config, lib, pkgs, vars, ... }:

let
  paths = config.repo.paperless.paths;
in
{
  options.repo.paperless.paths = {
    root = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/paperless";
      description = "Paperless data-pool root.";
    };

    inbox = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.paperless.paths.root}/inbox";
      description = "Paperless consume inbox root.";
    };

    handoffStaging = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.paperless.paths.root}/handoff-staging";
      description = "Paperless handoff staging root.";
    };

    archive = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.paperless.paths.root}/archive";
      description = "Paperless archive root.";
    };

    export = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.paperless.paths.root}/export";
      description = "Paperless export root.";
    };
  };

  config = {
    repo.storage.dataPool.guardedServices = [
      "paperless-storage-layout-v1"
      "paperless-consumer"
      "paperless-scheduler"
      "paperless-task-queue"
      "paperless-web"
      "paperless-exporter"
      "paperless-stale-reference-check"
    ];

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

        inbox_dir='${paths.inbox}'
        handoff_staging_dir='${paths.handoffStaging}'
        archive_dir='${paths.archive}'
        export_dir='${paths.export}'

        install -d -m 0755 -o root -g root '${paths.root}'
        install -d -m 2770 -o root -g paperless "$inbox_dir"
        install -d -m 2770 -o root -g paperless "$handoff_staging_dir"
        install -d -m 0750 -o paperless -g paperless "$archive_dir"
        install -d -m 0750 -o paperless -g paperless "$export_dir"
      '';
    };
  };
}
