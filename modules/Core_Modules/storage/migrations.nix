{ pkgs, vars, ... }:

{
  systemd.services.app-state-migration-v1 = {
    description = "Migrate app state from the old data-pool layout to SSD-backed paths";
    wantedBy = [ "multi-user.target" ];
    wants = [ "local-fs.target" ];
    after = [ "local-fs.target" ];
    before = [
      "audiobookshelf.service"
      "jellyfin.service"
      "kavita.service"
      "mail-archive-ui.service"
      "paperless-consumer.service"
      "paperless-scheduler.service"
      "paperless-task-queue.service"
      "paperless-web.service"
    ];
    path = [ pkgs.coreutils ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail

      marker_root="/persist/appdata/.nixos-managed/app-state-migration-v1"
      ${pkgs.coreutils}/bin/install -d -m 0755 /persist/appdata "$marker_root"

      migrate_dir() {
        local name="$1"
        local src="$2"
        local dest="$3"
        local owner="$4"
        local group="$5"
        local mode="$6"
        local marker_file="$marker_root/$name.done"

        if [[ -f "$marker_file" ]]; then
          return 0
        fi

        if [[ ! -d "$src" ]]; then
          ${pkgs.coreutils}/bin/touch "$marker_file"
          return 0
        fi

        ${pkgs.coreutils}/bin/install -d -m "$mode" -o "$owner" -g "$group" "$dest"

        if [[ -d "$src" ]]; then
          cp -a -n "$src"/. "$dest"/
        fi

        chown -R "$owner:$group" "$dest"
        chmod "$mode" "$dest"
        ${pkgs.coreutils}/bin/touch "$marker_file"
      }

      migrate_dir "audiobookshelf" "${vars.dataRoot}/appdata/audiobookshelf" "/var/lib/audiobookshelf" "audiobookshelf" "audiobookshelf" "0755"
      migrate_dir "jellyfin" "${vars.dataRoot}/appdata/jellyfin/server" "/var/lib/jellyfin" "jellyfin" "jellyfin" "0750"
      migrate_dir "kavita" "${vars.dataRoot}/appdata/kavita" "/var/lib/kavita" "kavita" "kavita" "0750"
      migrate_dir "paperless" "${vars.dataRoot}/appdata/paperless" "/var/lib/paperless" "paperless" "paperless" "0750"
      migrate_dir "mail-archive-ui" "${vars.dataRoot}/appdata/mail-archive-ui" "/persist/appdata/mail-archive-ui" "mail-archive-ui" "mail-archive-ui" "0750"
    '';
  };
}
