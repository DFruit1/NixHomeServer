{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    repo.impermanence.directories = [
      "/var/lib/jellyfin"
    ];
  };
}
