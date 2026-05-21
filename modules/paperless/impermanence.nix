{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.paperless.enable {
    repo.impermanence.directories = [
      "/var/lib/paperless"
      "/var/lib/redis-paperless"
    ];
  };
}
