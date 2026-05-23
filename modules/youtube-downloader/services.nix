{ config, lib, pkgs, vars, ... }:

let
  serviceUser = "youtube-downloader";
  serviceGroup = "youtube-downloader";
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.youtubeDownloader;
  stateRoot = "/var/lib/youtube-downloader";
  stateDir = "${stateRoot}/state";
  cacheRoot = "/var/cache/youtube-downloader";
  tempDir = "${cacheRoot}/tmp";
  sharedAudioRoot = "${vars.sharedAudiobooksRoot}/youtube";
  youtubeDownloader = pkgs.callPackage ../../node/apps/youtube-downloader { };
  resources = config.nixhomeserver.resources;
  oauth2Proxy = import ../lib/oauth2-proxy.nix { inherit lib pkgs vars; };
in
{
  config = lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable (lib.mkMerge [
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
          YOUTUBE_DOWNLOADER_STATE_DIR = stateDir;
          YOUTUBE_DOWNLOADER_DATABASE = "${stateDir}/youtube-downloader.sqlite";
          YOUTUBE_DOWNLOADER_TEMP_DIR = tempDir;
          YOUTUBE_DOWNLOADER_SHARED_VIDEO_ROOT = vars.sharedYouTubeRoot;
          YOUTUBE_DOWNLOADER_SHARED_AUDIO_ROOT = sharedAudioRoot;
          YOUTUBE_DOWNLOADER_USERS_ROOT = vars.usersRoot;
          YOUTUBE_DOWNLOADER_CONCURRENCY = "1";
          YOUTUBE_DOWNLOADER_SHARED_WRITE_GROUP = "user-files";
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
            stateRoot
            cacheRoot
            vars.sharedYouTubeRoot
            vars.sharedAudiobooksRoot
            vars.usersRoot
          ];
          CPUQuota = resources.youtubeDownloader.cpuQuota;
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
      domain = vars.downloadsDomain;
      port = vars.networking.ports.oauth2ProxyDownloads;
      upstream = "http://${listenAddress}:${toString listenPort}";
      allowedGroups = [ "downloads-users" ];
      serviceDependencies = [
        "caddy.service"
        "youtube-downloader.service"
      ];
      upstreamCheck = {
        displayName = "YouTube Downloader";
        url = "http://${listenAddress}:${toString listenPort}/healthz";
      };
    })
  ]);
}
