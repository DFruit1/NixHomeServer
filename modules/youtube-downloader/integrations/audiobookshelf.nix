{ config, lib, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps."youtube-downloader".enable
      && config.nixhomeserver.apps.audiobookshelf.enable
    )
    {
      systemd.services.youtube-downloader = {
        wants = [ "audiobookshelf-storage-layout-v1.service" ];
        after = [ "audiobookshelf-storage-layout-v1.service" ];
      };
    };
}
