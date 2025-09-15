# modules/apparmor/example-services.nix
{ config, lib, ... }:
{
  # Example: Copyparty
  systemd.services.copyparty.serviceConfig.AppArmorProfile = "copypartyd";

  # Example: Audiobookshelf
  systemd.services.audiobookshelf.serviceConfig.AppArmorProfile = "audiobookshelf";

  # Example: Immich (server)
  systemd.services.immich-server.serviceConfig.AppArmorProfile = "immich-server";

  # Example: Paperless-ngx
  systemd.services.paperless-ngx.serviceConfig.AppArmorProfile = "paperless-ngx";
}
