{ config, lib, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
  sharedEmailsRoot = config.repo.mailArchiveUi.paths.sharedEmailsRoot;
in
{
  config = lib.mkIf cfg.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "mail-archive-ui";
          component = "app";
          stateRoot = cfg.dataDir;
          payloadRoots = [
            cfg.storeRoot
            sharedEmailsRoot
          ];
          notes = "SQLite state, locks, and the app master key.";
        }
      ];
      criticalPaths = [
        sharedEmailsRoot
        cfg.dataDir
        cfg.accountStateRoot
        cfg.storeRoot
      ];
      sqliteDumps = [
        {
          source = "${cfg.dataDir}/mail-archive-ui.sqlite3";
          outputName = "mail-archive-ui.sqlite3";
        }
      ];
      prepareFragments."mail-archive-ui" = ''
        mail_archive_roots_file="${"$"}{metadataRoot}/mail-archive-roots.tsv"
        printf 'username\temails_root\temails_root_status\thidden_sync_root\thidden_sync_status\tvisible_eml_count\tattachment_blob_count\n' > "$mail_archive_roots_file"
        if mountpoint -q ${lib.escapeShellArg vars.dataRoot}; then
          if [[ -d ${lib.escapeShellArg cfg.storeRoot} ]]; then
            while IFS= read -r user_root; do
              username="$(basename -- "$user_root")"
              emails_root="$user_root/_Emails"
              hidden_sync_root="$emails_root/.internal-sync"

              if [[ -d "$emails_root" ]]; then
                emails_status="present"
                visible_eml_count="$(find "$emails_root" -path "$hidden_sync_root" -prune -o -type f -name '*.eml' -print 2>/dev/null | wc -l | tr -d ' ')"
              else
                emails_status="missing"
                visible_eml_count="0"
              fi

              if [[ -d "$hidden_sync_root" ]]; then
                hidden_status="present"
                attachment_blob_count="$(find "$hidden_sync_root" -path '*/attachments/blobs/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
              else
                hidden_status="missing"
                attachment_blob_count="0"
              fi

              printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$username" \
                "$emails_root" \
                "$emails_status" \
                "$hidden_sync_root" \
                "$hidden_status" \
                "$visible_eml_count" \
                "$attachment_blob_count"
            done < <(find ${lib.escapeShellArg cfg.storeRoot} -mindepth 1 -maxdepth 1 -type d | sort) >> "$mail_archive_roots_file"
          else
            printf '%s\t%s\tmissing\t%s\tmissing\t0\t0\n' "-" ${lib.escapeShellArg cfg.storeRoot} "-" >> "$mail_archive_roots_file"
          fi
        else
          printf '%s\t%s\tdata-root-not-mounted\t%s\tdata-root-not-mounted\t0\t0\n' "-" ${lib.escapeShellArg cfg.storeRoot} "-" >> "$mail_archive_roots_file"
        fi

        # Attachment verification and repair is intentionally operator-triggered.
        # Running it here made every backup mutate and rescan the full archive.
      '';
    };
  };
}
