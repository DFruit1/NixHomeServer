{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.audiobookshelf.enable {
    repo.impermanence.directories = [
      "/var/lib/audiobookshelf"
    ];
  };
}
