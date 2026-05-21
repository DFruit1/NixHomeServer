{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.kiwix.enable {
    repo.impermanence.directories = [
      "/var/lib/kiwix"
    ];
  };
}
