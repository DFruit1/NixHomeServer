{ config, pkgs, vars, ... }:

let
  dataDir = "/var/lib/audiobookshelf";
  configDir = "${dataDir}/config";
  metadataDir = "${dataDir}/metadata";
  backupDir = "${metadataDir}/backups";
  managedDir = "${dataDir}/.nixos-managed";
in
{
  systemd.services.audiobookshelf-storage-migration-v1 = {
    description = "Normalize Audiobookshelf storage paths after migration";
    before = [
      "audiobookshelf.service"
      "audiobookshelf-oidc-bootstrap-v1.service"
      "audiobookshelf-root-bootstrap-v1.service"
    ];
    wantedBy = [ "multi-user.target" ];
    path = with pkgs; [
      coreutils
      jq
      sqlite
    ];
    serviceConfig = {
      Type = "oneshot";
      User = "audiobookshelf";
      Group = "audiobookshelf";
    };
    script = ''
      set -euo pipefail

      db="${configDir}/absdatabase.sqlite"
      legacy_root="${vars.dataRoot}/audiobookshelf"
      data_dir="${dataDir}"
      backup_dir="${backupDir}"
      managed_dir="${managedDir}"
      marker_file="$managed_dir/audiobookshelf-storage-migration-v1.done"

      install -d -m 0755 \
        "${configDir}" \
        "${metadataDir}" \
        "$backup_dir" \
        "$managed_dir"

      if [[ -f "$marker_file" ]]; then
        echo "Audiobookshelf storage migration v1 already applied"
        exit 0
      fi

      [[ -f "$db" ]] || exit 0

      current="$(${pkgs.sqlite}/bin/sqlite3 -readonly "$db" \
        "select value from settings where key = 'server-settings';")"
      [[ -n "$current" ]] || exit 0

      updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
        --arg legacyRoot "$legacy_root" \
        --arg dataDir "$data_dir" \
        --arg backupDir "$backup_dir" \
        '
          walk(
            if type == "string" then
              gsub($legacyRoot; $dataDir)
            else
              .
            end
          )
          | .backupPath = $backupDir
        ')"

      if [[ "$current" == "$updated" ]]; then
        echo "Audiobookshelf storage migration v1 already converged"
        touch "$marker_file"
        exit 0
      fi

      escaped="$(
        printf '%s' "$updated" |
          ${pkgs.perl}/bin/perl -pe 's/\x27/\x27\x27/g'
      )"

      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update settings set value = '$escaped' where key = 'server-settings';"
      ${pkgs.sqlite}/bin/sqlite3 "$db" \
        "update settings set updatedAt = datetime('now') where key = 'server-settings';"

      echo "Audiobookshelf storage migration v1 updated stored paths"
      touch "$marker_file"
    '';
  };
}
