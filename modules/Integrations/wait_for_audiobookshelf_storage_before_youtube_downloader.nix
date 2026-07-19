{ config, lib, options, ... }:

{
  config = lib.optionalAttrs (
    lib.hasAttrByPath [ "repo" "youtubeDownloader" ] options
    && lib.hasAttrByPath [ "repo" "audiobookshelf" ] options
  ) {
    repo.youtubeDownloader.paths.sharedAudiobooksRoot = "${config.repo.audiobookshelf.paths.sharedAudiobooksRoot}/_YouTube";

    systemd.services.youtube-downloader = {
      wants = [ "audiobookshelf-storage-layout-v1.service" ];
      after = [ "audiobookshelf-storage-layout-v1.service" ];
    };
  };
}
