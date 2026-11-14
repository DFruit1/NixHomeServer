{ config, lib, options, ... }:

# Finished downloads name their exact output files in Media Manager's index
# hint directory, so they appear in the library immediately without waiting
# for (or forcing) a full library scan.
let
  mediaManager = config.repo.mediaManager;
in
{
  config = lib.optionalAttrs (lib.hasAttrByPath [ "repo" "youtubeDownloader" ] options) {
    systemd.services.youtube-downloader = {
      environment.YOUTUBE_DOWNLOADER_MEDIA_INDEX_HINT_DIR = mediaManager.indexHintDir;
      serviceConfig = {
        SupplementaryGroups = [ mediaManager.indexHintGroup ];
        # "-": a missing drop directory must never stop downloads; hints are best effort.
        ReadWritePaths = [ "-${mediaManager.indexHintDir}" ];
      };
    };
  };
}
