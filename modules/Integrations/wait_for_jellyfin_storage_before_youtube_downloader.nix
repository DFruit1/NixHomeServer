{ config, ... }:

{
  repo.youtubeDownloader.paths.sharedVideoRoot = "${config.repo.jellyfin.paths.sharedVideosRoot}/_YouTube";

  systemd.services.youtube-downloader = {
    wants = [ "media-folder-layout-v2.service" "jellyfin-storage-layout-v1.service" ];
    after = [ "media-folder-layout-v2.service" "jellyfin-storage-layout-v1.service" ];
  };
}
