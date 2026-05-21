{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.kavita.enable {
    repo.impermanence.directories = [
      "/var/lib/kavita"
    ];
  };
}
