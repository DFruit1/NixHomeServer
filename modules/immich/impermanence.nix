{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    repo.impermanence.directories = [
      "/var/cache/immich"
      "/var/lib/immich"
      "/var/lib/immich-public-proxy"
      "/var/lib/postgresql/16"
      "/var/lib/redis-immich"
    ];
  };
}
