{ config, lib, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
    repo.impermanence.directories = [
      "/var/lib/vaultwarden"
    ];
  };
}
