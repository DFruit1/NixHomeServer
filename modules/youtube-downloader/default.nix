{ config, lib, pkgs, vars, ... }:

let
  metubeUser = "metube";
  metubeGroup = "metube";
  metubeUid = 3002;
  metubeGid = 3002;
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.metube;
  stateRoot = "/var/lib/metube";
  stateDir = "${stateRoot}/state";
  cacheRoot = "/var/cache/youtube-downloader";
  tempDir = "${cacheRoot}/tmp";
  sharedAudioRoot = "${vars.sharedAudiobooksRoot}/youtube";
  youtubeDownloader = pkgs.callPackage ../../node/apps/youtube-downloader { };
  resources = config.nixhomeserver.resources;
in
{
  config = lib.mkIf config.nixhomeserver.apps.metube.enable {
    users.groups.${metubeGroup} = {
      gid = metubeGid;
    };

    users.users.${metubeUser} = {
      isSystemUser = true;
      uid = metubeUid;
      group = metubeGroup;
      extraGroups = [ "users" ];
      home = stateRoot;
      createHome = true;
    };

    systemd.tmpfiles.rules = [
      "d ${stateRoot} 0750 ${metubeUser} ${metubeGroup} -"
      "d ${stateDir} 0750 ${metubeUser} ${metubeGroup} -"
      "d ${cacheRoot} 0750 ${metubeUser} ${metubeGroup} -"
      "d ${tempDir} 0750 ${metubeUser} ${metubeGroup} -"
    ];

    systemd.services.youtube-downloader = {
      description = "Authenticated YouTube media downloader";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "data-pool-layout.service"
        "jellyfin-storage-layout-v1.service"
        "audiobookshelf-storage-layout-v1.service"
      ];
      after = [
        "network-online.target"
        "data-pool-layout.service"
        "jellyfin-storage-layout-v1.service"
        "audiobookshelf-storage-layout-v1.service"
      ];
      path = with pkgs; [
        coreutils
        ffmpeg
        sqlite
        yt-dlp
      ];
      environment = {
        YOUTUBE_DOWNLOADER_HOST = listenAddress;
        YOUTUBE_DOWNLOADER_PORT = toString listenPort;
        YOUTUBE_DOWNLOADER_STATE_DIR = stateDir;
        YOUTUBE_DOWNLOADER_DATABASE = "${stateDir}/youtube-downloader.sqlite";
        YOUTUBE_DOWNLOADER_TEMP_DIR = tempDir;
        YOUTUBE_DOWNLOADER_SHARED_VIDEO_ROOT = vars.sharedYouTubeRoot;
        YOUTUBE_DOWNLOADER_SHARED_AUDIO_ROOT = sharedAudioRoot;
        YOUTUBE_DOWNLOADER_USERS_ROOT = vars.usersRoot;
        YOUTUBE_DOWNLOADER_CONCURRENCY = "1";
        YOUTUBE_DOWNLOADER_SHARED_WRITE_GROUP = "shared-files-read-write-access";
      };
      serviceConfig = {
        Type = "simple";
        User = metubeUser;
        Group = metubeGroup;
        SupplementaryGroups = [ "users" ];
        ExecStart = "${youtubeDownloader}/bin/youtube-downloader";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "60s";
        UMask = "0002";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          stateRoot
          cacheRoot
          vars.sharedYouTubeRoot
          vars.sharedAudiobooksRoot
          vars.usersRoot
        ];
        CPUQuota = resources.metube.cpuQuota;
      };
    };
  };
}
