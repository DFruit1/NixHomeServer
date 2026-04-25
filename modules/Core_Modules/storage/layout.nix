{ lib, pkgs, vars, ... }:

let
  mailArchiveStoreRoot = "${vars.dataRoot}/mail-archive";
  immichManagedPhotosRoot = "${vars.mediaRoot}/photos/managed";
  immichExternalPhotosRoot = "${vars.mediaRoot}/photos/external";
  paperlessInboxDir = "${vars.mediaRoot}/documents/inbox";
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
      path = paperlessInboxDir;
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
      mode = "0750";
      user = "paperless";
      group = "paperless";
    }
    {
      path = audiobooksRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = podcastsRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = ebooksRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = comicsRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = mangaRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = moviesRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = showsRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
    }
    {
      path = homeVideosRoot;
      mode = "2775";
      user = "root";
      group = "media-library";
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
  users.groups.media-library = { };

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
}
