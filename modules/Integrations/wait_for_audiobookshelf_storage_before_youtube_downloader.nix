{ config, ... }:

{
  repo.youtubeDownloader.paths.sharedAudioRoot = "${config.repo.audiobookshelf.paths.sharedAudiobooksRoot}/_YouTube";

  systemd.services.youtube-downloader = {
    wants = [ "audiobookshelf-storage-layout-v1.service" ];
    after = [ "audiobookshelf-storage-layout-v1.service" ];
  };
}
