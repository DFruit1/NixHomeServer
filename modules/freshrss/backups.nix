{ config, lib, ... }:

let
  cfg = config.repo.freshrss;
  username = import ./username.nix;
in
{
  config = lib.mkIf cfg.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "freshrss";
          component = "app";
          stateRoot = cfg.stateDir;
          payloadRoots = [ ];
          notes = "FreshRSS system configuration, per-user settings, subscriptions, and SQLite databases.";
        }
      ];

      # FreshRSS creates one SQLite database per auto-registered user, so the
      # fixed-path sqliteDumps inventory cannot describe the set ahead of time.
      # Use FreshRSS's online backup command, then publish and integrity-check
      # every database it produced in the central backup generation.
      prepareFragments.freshrss = ''
        freshrss_config=${lib.escapeShellArg "${cfg.stateDir}/config.php"}
        freshrss_users=${lib.escapeShellArg "${cfg.stateDir}/users"}
        if [[ -f "$freshrss_config" ]]; then
          echo "Preparing FreshRSS per-user SQLite backups"
          runuser -u freshrss -- env \
            DATA_PATH=${lib.escapeShellArg cfg.stateDir} \
            ${cfg.package}/cli/db-backup.php --quiet

          freshrss_backup_count=0
          if [[ -d "$freshrss_users" ]]; then
            while IFS= read -r -d ''' freshrss_source; do
              freshrss_username="$(basename "$(dirname "$freshrss_source")")"
              if [[ ! "$freshrss_username" =~ ${username.shellPattern} ]]; then
                echo "Refusing unsafe FreshRSS backup username: $freshrss_username" >&2
                exit 1
              fi
              freshrss_output_name="freshrss-$freshrss_username.sqlite"
              freshrss_output="$dumpsRoot/$freshrss_output_name"
              cp -- "$freshrss_source" "$freshrss_output"
              freshrss_integrity="$(sqlite3 -readonly "$freshrss_output" 'PRAGMA integrity_check;')"
              if [[ "$freshrss_integrity" != ok ]]; then
                echo "FreshRSS SQLite integrity check failed for $freshrss_username: $freshrss_integrity" >&2
                exit 1
              fi
              (
                cd "$work"
                sha256sum -- "dumps/$freshrss_output_name"
              ) >> "$work/metadata/SHA256SUMS"
              ((freshrss_backup_count += 1))
            done < <(find "$freshrss_users" -mindepth 2 -maxdepth 2 -type f -name backup.sqlite -print0)
          fi
          echo "Prepared $freshrss_backup_count FreshRSS SQLite backup(s)"
        else
          echo "FreshRSS is not initialized; no logical database backup is required yet"
        fi
      '';
    };
  };
}
