{ lib, pkgs, vars, ... }:

let
  mailArchiveStoreRoot = "${vars.dataRoot}/mail-archive";
  immichManagedPhotosRoot = "${vars.mediaRoot}/photos/managed";
  immichExternalPhotosRoot = "${vars.mediaRoot}/photos/external";
  paperlessConsumeDir = "${vars.mediaRoot}/documents/consume";
  paperlessArchiveDir = "${vars.mediaRoot}/documents/archive";
  paperlessExportDir = "${vars.mediaRoot}/documents/export";
  audiobooksRoot = "${vars.mediaRoot}/audio/audiobooks";
  podcastsRoot = "${vars.mediaRoot}/audio/podcasts";
  ebooksRoot = "${vars.mediaRoot}/books/ebooks";
  comicsRoot = "${vars.mediaRoot}/books/comics";
  mangaRoot = "${vars.mediaRoot}/books/manga";
  moviesRoot = "${vars.mediaRoot}/video/movies";
  showsRoot = "${vars.mediaRoot}/video/shows";
  homeVideosRoot = "${vars.mediaRoot}/video/home";
  sharedExchangeRoot = "${vars.sharedWorkspaceRoot}/exchange";

  mkDirCmd =
    {
      path,
      mode,
      user,
      group,
    }:
    "${pkgs.coreutils}/bin/install -d -m ${mode} -o ${user} -g ${group} '${path}'";

  mkImmichSentinelCmd = path: ''
    ${pkgs.coreutils}/bin/touch '${path}'
    ${pkgs.coreutils}/bin/chown immich:immich '${path}'
    ${pkgs.coreutils}/bin/chmod 0640 '${path}'
  '';

  zfsContentDirs = [
    {
      path = vars.dataRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.mediaRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.workspaceRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.usersWorkspaceRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = vars.sharedWorkspaceRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = mailArchiveStoreRoot;
      mode = "0750";
      user = "mail-archive-ui";
      group = "mail-archive-ui";
    }
    {
      path = "${mailArchiveStoreRoot}/users";
      mode = "0750";
      user = "mail-archive-ui";
      group = "mail-archive-ui";
    }
    {
      path = immichManagedPhotosRoot;
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/backups";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/encoded-video";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/library";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/profile";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/thumbs";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = "${immichManagedPhotosRoot}/upload";
      mode = "0750";
      user = "immich";
      group = "immich";
    }
    {
      path = immichExternalPhotosRoot;
      mode = "2770";
      user = "root";
      group = "immich";
    }
    {
      path = paperlessConsumeDir;
      mode = "2770";
      user = "root";
      group = "paperless";
    }
    {
      path = paperlessArchiveDir;
      mode = "0750";
      user = "paperless";
      group = "paperless";
    }
    {
      path = paperlessExportDir;
      mode = "0770";
      user = "paperless";
      group = "paperless";
    }
    {
      path = audiobooksRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = podcastsRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = ebooksRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = comicsRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = mangaRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = moviesRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = showsRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = homeVideosRoot;
      mode = "0755";
      user = "root";
      group = "root";
    }
    {
      path = sharedExchangeRoot;
      mode = "2775";
      user = "root";
      group = "users";
    }
    {
      path = vars.sharedPublicRoot;
      mode = "2775";
      user = "root";
      group = "users";
    }
  ];

  zfsContentLayoutScript = lib.concatStringsSep "\n" (
    (map mkDirCmd zfsContentDirs)
    ++ map mkImmichSentinelCmd [
      "${immichManagedPhotosRoot}/backups/.immich"
      "${immichManagedPhotosRoot}/encoded-video/.immich"
      "${immichManagedPhotosRoot}/library/.immich"
      "${immichManagedPhotosRoot}/profile/.immich"
      "${immichManagedPhotosRoot}/thumbs/.immich"
      "${immichManagedPhotosRoot}/upload/.immich"
    ]
  );
in
{
  systemd.tmpfiles.rules = [
    "d /persist/appdata 0755 root root -"
    "d /persist/appdata/mail-archive-ui 0750 mail-archive-ui mail-archive-ui -"
    "d ${vars.coldStorageMountPoint} 0750 root root -"
  ] ++ map (pool: "d ${pool.mountPoint} 0750 root root -") vars.coldStoragePools;

  systemd.services.data-pool-layout = {
    description = "Provision data-pool-backed content layout";
    wantedBy = [ "multi-user.target" ];
    wants = [ "local-fs.target" ];
    after = [ "local-fs.target" ];
    before = [
      "audiobookshelf.service"
      "copyparty.service"
      "jellyfin.service"
      "mail-archive-sync.service"
      "mail-archive-ui.service"
      "paperless-consumer.service"
      "paperless-scheduler.service"
      "paperless-task-queue.service"
      "paperless-web.service"
      "samba-smbd.service"
    ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      set -euo pipefail
      ${zfsContentLayoutScript}
    '';
  };

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
