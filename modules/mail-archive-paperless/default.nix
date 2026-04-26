{ config, lib, pkgs, vars, ... }:

let
  mailArchiveCfg = config.services.mail-archive-ui;
  paperlessCfg = config.services.paperless;
  paperlessConsumeRoot = "${paperlessCfg.consumptionDir}/mail-archive";
  paperlessStagingDir = "${vars.mediaRoot}/documents/.mail-archive-paperless-staging";
in
{
  config = lib.mkIf (mailArchiveCfg.enable && paperlessCfg.enable) {
    services.mail-archive-ui.environment = {
      MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT = paperlessConsumeRoot;
      MAIL_ARCHIVE_UI_PAPERLESS_STAGING_DIR = paperlessStagingDir;
    };

    services.paperless.settings = {
      PAPERLESS_CONSUMER_RECURSIVE = "true";
      PAPERLESS_CONSUMER_SUBDIRS_AS_TAGS = "true";
    };

    systemd.services.mail-archive-ui = {
      path = lib.mkAfter [
        pkgs.file
        pkgs.ripmime
      ];
      serviceConfig.ReadWritePaths = lib.mkAfter [
        paperlessConsumeRoot
        paperlessStagingDir
      ];
    };

    systemd.services.mail-archive-sync = {
      path = lib.mkAfter [
        pkgs.file
        pkgs.ripmime
      ];
      serviceConfig.ReadWritePaths = lib.mkAfter [
        paperlessConsumeRoot
        paperlessStagingDir
      ];
    };
  };
}
