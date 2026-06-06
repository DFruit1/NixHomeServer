{ config, lib, vars, ... }:

let
  paths = config.repo.youtubeDownloader.paths;
  userVideoWritablePaths = map (name: "_Videos/${name}") config.repo.storage.userRoots.videoSubdirs;
in
{
  options.repo.youtubeDownloader.paths = {
    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/youtube-downloader";
      description = "YouTube Downloader persistent state root.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.youtubeDownloader.paths.stateRoot}/state";
      description = "YouTube Downloader SQLite and queue state directory.";
    };

    cacheRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/cache/youtube-downloader";
      description = "YouTube Downloader cache root.";
    };

    tempDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.youtubeDownloader.paths.cacheRoot}/tmp";
      description = "YouTube Downloader temporary download directory.";
    };

    sharedVideoRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_YouTubeVideos";
      description = "Shared video output root. Integration modules may bind this to a media app library.";
    };

    sharedAudioRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_YouTubeAudio";
      description = "Shared audio output root. Integration modules may bind this to a media app library.";
    };
  };

  config = {
    repo.storage.userRoots.recursiveWritableGrants = [
      {
        group = "youtube-downloader";
        relativePaths = [
          "_Audiobooks"
          "_Videos"
        ] ++ userVideoWritablePaths;
      }
    ];

    systemd.tmpfiles.rules = [
      "d ${paths.stateRoot} 0750 youtube-downloader youtube-downloader -"
      "d ${paths.stateDir} 0750 youtube-downloader youtube-downloader -"
      "d ${paths.cacheRoot} 0750 youtube-downloader youtube-downloader -"
      "d ${paths.tempDir} 0750 youtube-downloader youtube-downloader -"
      "d ${paths.sharedVideoRoot} 1770 root root -"
      "d ${paths.sharedAudioRoot} 1770 root root -"
    ];
  };
}
