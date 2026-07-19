{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  serviceUser = "youtube-downloader";
  serviceGroup = "youtube-downloader";
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.youtubeDownloader;
  paths = config.repo.youtubeDownloader.paths;
  youtubeDownloader = pkgs.callPackage ../../custom_apps/node/apps/youtube-downloader { };
  ownershipMigrationMarker = "/persist/appdata/migrations/youtube-downloader-ownership-v1";
  repairStateOwnership = pkgs.writeShellScript "youtube-downloader-repair-state-ownership" ''
    set -euo pipefail
    expected_identity="$(${pkgs.coreutils}/bin/id -u ${serviceUser}):$(${pkgs.coreutils}/bin/id -g ${serviceUser})"
    if [[ -f ${lib.escapeShellArg ownershipMigrationMarker} ]] \
      && [[ "$(<${lib.escapeShellArg ownershipMigrationMarker})" == "$expected_identity" ]]; then
      exit 0
    fi

    ${pkgs.coreutils}/bin/chown -R ${serviceUser}:${serviceGroup} \
      ${lib.escapeShellArg paths.stateRoot} \
      ${lib.escapeShellArg paths.cacheRoot}
    ${pkgs.coreutils}/bin/install -d -m 0700 -o root -g root \
      ${lib.escapeShellArg (builtins.dirOf ownershipMigrationMarker)}
    marker_tmp="$(${pkgs.coreutils}/bin/mktemp ${lib.escapeShellArg "${builtins.dirOf ownershipMigrationMarker}/.youtube-ownership.XXXXXX"})"
    trap 'rm -f "$marker_tmp"' EXIT
    printf '%s\n' "$expected_identity" >"$marker_tmp"
    ${pkgs.coreutils}/bin/chown root:root "$marker_tmp"
    ${pkgs.coreutils}/bin/chmod 0400 "$marker_tmp"
    ${pkgs.coreutils}/bin/mv "$marker_tmp" ${lib.escapeShellArg ownershipMigrationMarker}
    trap - EXIT
  '';
  host = "ytdownload.${vars.domain}";
in
{
  options.repo.youtubeDownloader.eventRetentionDays = lib.mkOption {
    type = lib.types.ints.positive;
    default = 90;
    description = "Retention period for detailed events belonging to terminal download jobs.";
  };

  config = lib.mkMerge [
    {
      systemd.services.youtube-downloader-ownership-migration = {
        description = "One-time YouTube Downloader dynamic-identity ownership migration";
        before = [ "youtube-downloader.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "+${repairStateOwnership}";
          TimeoutStartSec = "2h";
          Nice = 10;
          IOWeight = 20;
        };
      };

      systemd.services.youtube-downloader = {
        description = "Authenticated YouTube media downloader";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "data-pool-layout.service"
          "fileshare-user-root-sync.service"
          "youtube-downloader-ownership-migration.service"
        ];
        wants = [
          "network-online.target"
        ];
        after = [
          "network-online.target"
          "data-pool-layout.service"
          "fileshare-user-root-sync.service"
          "youtube-downloader-ownership-migration.service"
        ];
        unitConfig = lib.mkMerge [
          {
            StartLimitIntervalSec = "5min";
            StartLimitBurst = 5;
            RequiresMountsFor = [ vars.dataRoot ];
          }
          (lib.mkIf vars.dataRootIsMountPoint {
            ConditionPathIsMountPoint = vars.dataRoot;
          })
        ];
        path = with pkgs; [
          coreutils
          ffmpeg
          nodejs
          python3
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
          YOUTUBE_DOWNLOADER_SHARED_ROOT = vars.sharedRoot;
          YOUTUBE_DOWNLOADER_CONCURRENCY = "1";
          YOUTUBE_DOWNLOADER_SHARED_WRITE_GROUP = vars.fileAccess.sharedAccessGroup or "files-shared-users";
          YOUTUBE_DOWNLOADER_FILE_BROWSER_SHARED_MOUNT_NAME = vars.fileAccess.sharedMountName or "_Shared";
          YOUTUBE_DOWNLOADER_EVENT_RETENTION_DAYS = toString config.repo.youtubeDownloader.eventRetentionDays;
        };
        serviceConfig = {
          Type = "simple";
          User = serviceUser;
          Group = serviceGroup;
          SupplementaryGroups = [
            "users"
            (vars.fileAccess.sharedAccessGroup or "files-shared-users")
          ];
          ExecStart = "${youtubeDownloader}/bin/youtube-downloader";
          Restart = "on-failure";
          RestartSec = "5s";
          TimeoutStartSec = "60s";
          TimeoutStopSec = "20s";
          MemoryHigh = "1G";
          MemoryMax = "2G";
          OOMPolicy = "stop";
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
