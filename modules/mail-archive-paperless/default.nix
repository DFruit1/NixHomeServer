{ config, lib, pkgs, vars, ... }:

let
  mailArchiveCfg = config.services.mail-archive-ui;
  paperlessCfg = config.services.paperless;
  paperlessConsumeRoot = "${paperlessCfg.consumptionDir}/mail-archive";
  paperlessStagingDir = vars.paperlessMailArchiveStagingRoot;
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

    systemd.tmpfiles.rules = [
      "d ${paperlessStagingDir} 0770 mail-archive-ui mail-archive-ui -"
    ];

    system.activationScripts.mailArchivePaperlessStagingDir = lib.stringAfter [ "users" "groups" ] ''
      mkdir -p ${lib.escapeShellArg paperlessConsumeRoot}
      chown root:paperless ${lib.escapeShellArg paperlessConsumeRoot}
      chmod 2770 ${lib.escapeShellArg paperlessConsumeRoot}
      ${pkgs.acl}/bin/setfacl \
        -m u:mail-archive-ui:--x \
        ${lib.escapeShellArg paperlessCfg.consumptionDir}
      ${pkgs.acl}/bin/setfacl \
        -m u:mail-archive-ui:rwx \
        -m d:u:mail-archive-ui:rwx \
        ${lib.escapeShellArg paperlessConsumeRoot}

      mkdir -p ${lib.escapeShellArg paperlessStagingDir}
      chown mail-archive-ui:mail-archive-ui ${lib.escapeShellArg paperlessStagingDir}
      chmod 0770 ${lib.escapeShellArg paperlessStagingDir}
    '';
  };
}
