{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps."youtube-downloader".enable {
    repo.impermanence.directories = [
      "/var/lib/youtube-downloader"
    ];
  };
}
