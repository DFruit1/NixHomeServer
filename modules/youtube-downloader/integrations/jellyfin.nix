{ config, lib, ... }:

{
  config = lib.mkIf
    (
      config.nixhomeserver.apps."youtube-downloader".enable
      && config.nixhomeserver.apps.jellyfin.enable
    )
    {
      systemd.services.youtube-downloader = {
        wants = [ "jellyfin-storage-layout-v1.service" ];
        after = [ "jellyfin-storage-layout-v1.service" ];
      };
    };
}
