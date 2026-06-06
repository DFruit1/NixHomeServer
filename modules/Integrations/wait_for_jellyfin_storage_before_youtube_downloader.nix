{ config, ... }:

{
  repo.youtubeDownloader.paths.sharedVideoRoot = "${config.repo.jellyfin.paths.sharedVideosRoot}/_YouTube";

  systemd.services.youtube-downloader = {
    wants = [ "jellyfin-storage-layout-v1.service" ];
    after = [ "jellyfin-storage-layout-v1.service" ];
  };
}
