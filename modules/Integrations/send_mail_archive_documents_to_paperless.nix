{ config, lib, options, pkgs, ... }:

let
  mailArchivePresent =
    lib.hasAttrByPath [ "repo" "mailArchiveUi" ] options
    && lib.hasAttrByPath [ "services" "mail-archive-ui" "enable" ] options;
  paperlessPresent = lib.hasAttrByPath [ "repo" "paperless" ] options;
in
{
  config = lib.optionalAttrs
    (
      mailArchivePresent
      && paperlessPresent
    )
    (lib.mkIf config.services.mail-archive-ui.enable {
      # Never point Mail Archive at Paperless's live SQLite file. Paperless may
      # have committed state in WAL files, and opening the main file as an
      # immutable database can therefore return a stale view. A periodic SQLite
      # backup gives duplicate detection a consistent, self-contained snapshot.
      services.mail-archive-ui = {
        paperlessConsumeRoot = lib.mkDefault "${config.repo.paperless.paths.inbox}/mail-archive";
        paperlessHandoffStagingRoot = lib.mkDefault config.repo.paperless.paths.handoffStaging;
        paperlessDatabasePath = lib.mkDefault "${config.services.mail-archive-ui.runtimeDir}/paperless-db-snapshot.sqlite3";
      };

      systemd.services.mail-archive-ui-paperless-db-snapshot = {
        description = "Create a consistent Paperless database snapshot for Mail Archive duplicate detection";
        wantedBy = [ "multi-user.target" ];
        before = [
          "mail-archive-ui.service"
          "mail-archive-paperless-tasks.service"
        ];
        wants = [ "paperless-web.service" ];
        after = [ "paperless-web.service" ];
        path = [
          pkgs.coreutils
          pkgs.sqlite
        ];
        unitConfig.RequiresMountsFor = [ config.services.mail-archive-ui.runtimeDir ];
        serviceConfig = {
          Type = "oneshot";
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadOnlyPaths = [ "/var/lib/paperless" ];
          ReadWritePaths = [ config.services.mail-archive-ui.runtimeDir ];
        };
        script = ''
          set -euo pipefail

          paperless_db='/var/lib/paperless/db.sqlite3'
          snapshot=${lib.escapeShellArg config.services.mail-archive-ui.paperlessDatabasePath}
          temporary="''${snapshot}.new"
          trap 'rm -f "$temporary"' EXIT

          [[ -s "$paperless_db" ]] || {
            echo "Paperless database is not ready: $paperless_db" >&2
            exit 1
          }

          rm -f "$temporary"
          sqlite3 -readonly -cmd '.timeout 15000' "$paperless_db" ".backup '$temporary'"
          [[ "$(sqlite3 -readonly "$temporary" 'PRAGMA quick_check;')" == ok ]] || {
            echo "Paperless database snapshot failed its integrity check" >&2
            exit 1
          }
          [[ "$(sqlite3 -readonly "$temporary" \
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'documents_document';")" == 1 ]] || {
              echo "Paperless database snapshot is missing documents_document" >&2
              exit 1
            }

          chown mail-archive-ui:mail-archive-ui "$temporary"
          chmod 0440 "$temporary"
          mv -f "$temporary" "$snapshot"
        '';
      };

      systemd.timers.mail-archive-ui-paperless-db-snapshot = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = "1m";
          OnUnitActiveSec = "2m";
          AccuracySec = "15s";
          Persistent = true;
        };
      };

      systemd.services.mail-archive-ui = {
        wants = [ "mail-archive-ui-paperless-db-snapshot.service" ];
        after = [ "mail-archive-ui-paperless-db-snapshot.service" ];
      };

      systemd.services.mail-archive-paperless-tasks = {
        requires = [ "mail-archive-ui-paperless-db-snapshot.service" ];
        after = [ "mail-archive-ui-paperless-db-snapshot.service" ];
      };
    });
}
