{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.files.enable {
    repo.impermanence.directories = [
      "/var/cache/filestash"
      "/var/lib/filestash"
      "/var/log/filestash"
    ];
  };
}
