{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.copyparty.enable {
    repo.impermanence.directories = [
      "/var/lib/clamav"
      "/var/lib/copyparty"
      "/var/lib/upload-processor"
    ];
  };
}
