{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  serviceUser = "youtube-downloader";
  serviceGroup = "youtube-downloader";
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.youtubeDownloader;
  paths = config.repo.youtubeDownloader.paths;
  youtubeDownloader = pkgs.callPackage ../../custom_apps/node/apps/youtube-downloader { };
  host = "ytdownload.${vars.domain}";
in
{
  config = lib.mkMerge [
    {
      systemd.services.youtube-downloader = {
        description = "Authenticated YouTube media downloader";
        wantedBy = [ "multi-user.target" ];
        wants = [
          "network-online.target"
          "data-pool-layout.service"
        ];
        after = [
          "network-online.target"
          "data-pool-layout.service"
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
          YOUTUBE_DOWNLOADER_STATE_DIR = paths.stateDir;
          YOUTUBE_DOWNLOADER_DATABASE = "${paths.stateDir}/youtube-downloader.sqlite";
          YOUTUBE_DOWNLOADER_TEMP_DIR = paths.tempDir;
          YOUTUBE_DOWNLOADER_SHARED_VIDEO_ROOT = paths.sharedVideoRoot;
          YOUTUBE_DOWNLOADER_SHARED_AUDIO_ROOT = paths.sharedAudioRoot;
          YOUTUBE_DOWNLOADER_SHARED_AUDIOBOOKS_ROOT = paths.sharedAudiobooksRoot;
          YOUTUBE_DOWNLOADER_USERS_ROOT = vars.usersRoot;
          YOUTUBE_DOWNLOADER_CONCURRENCY = "1";
          YOUTUBE_DOWNLOADER_SHARED_WRITE_GROUP = vars.fileAccess.sharedAccessGroup or "files-shared-users";
        };
        serviceConfig = {
          Type = "simple";
          User = serviceUser;
          Group = serviceGroup;
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
            paths.stateRoot
            paths.cacheRoot
            paths.sharedVideoRoot
            paths.sharedAudioRoot
            paths.sharedAudiobooksRoot
            vars.usersRoot
          ];
        };
      };
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "youtube-downloader-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for YouTube Downloader";
      clientId = "youtube-downloader-web";
      clientSecretFile = config.age.secrets.youtubeDownloaderOauth2ProxyClientSecret.path;
      cookieSecretFile = config.age.secrets.youtubeDownloaderOauth2ProxyCookieSecret.path;
      cookieName = "_oauth2_proxy_youtube_downloader";
      domain = host;
      port = vars.networking.ports.oauth2ProxyDownloads;
      upstream = "http://${listenAddress}:${toString listenPort}";
      allowedGroups = [ "downloads-users" ];
      codeChallengeMethod = "S256";
      serviceDependencies = [
        "caddy.service"
        "youtube-downloader.service"
      ];
      upstreamCheck = {
        displayName = "YouTube Downloader";
        url = "http://${listenAddress}:${toString listenPort}/healthz";
      };
    })
  ];
}
