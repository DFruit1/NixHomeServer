{ config, lib, options, pkgs, ... }:

{
  config = lib.optionalAttrs (
    lib.hasAttrByPath [ "repo" "mailArchiveUi" ] options
    && lib.hasAttrByPath [ "repo" "paperless" ] options
  ) {
    services.mail-archive-ui = {
      paperlessConsumeRoot = lib.mkDefault config.repo.paperless.paths.inbox;
      paperlessHandoffStagingRoot = lib.mkDefault config.repo.paperless.paths.handoffStaging;
      paperlessDatabasePath = lib.mkDefault "/var/lib/paperless/db.sqlite3";
    };

    users.users.mail-archive-ui.extraGroups = lib.mkAfter [
      "paperless"
    ];

    systemd.services.mail-archive-ui-paperless-db-acl = {
      description = "Grant Mail Archive read access to the Paperless duplicate-check database";
      wantedBy = [ "multi-user.target" ];
      before = [
        "mail-archive-ui.service"
        "mail-archive-paperless-tasks.service"
      ];
      wants = [ "paperless-web.service" ];
      after = [ "paperless-web.service" ];
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

        paperless_db='/var/lib/paperless/db.sqlite3'
        if [[ ! -f "$paperless_db" ]]; then
          exit 0
        fi

        setfacl -m u:mail-archive-ui:--x /var/lib/paperless
        setfacl -m u:mail-archive-ui:r "$paperless_db"
      '';
    };

    systemd.services.mail-archive-ui = {
      wants = [ "mail-archive-ui-paperless-db-acl.service" ];
      after = [ "mail-archive-ui-paperless-db-acl.service" ];
    };

    systemd.services.mail-archive-paperless-tasks = {
      wants = [ "mail-archive-ui-paperless-db-acl.service" ];
      after = [ "mail-archive-ui-paperless-db-acl.service" ];
    };
  };
}
