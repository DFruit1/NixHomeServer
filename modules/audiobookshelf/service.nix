{ lib, ... }:

let
  audiobookshelfPort = 13378;
  dataDir = "/var/lib/audiobookshelf";
in
{
  services.audiobookshelf = {
    enable = true;
    dataDir = "audiobookshelf";
    port = audiobookshelfPort;
  };

  users.users.audiobookshelf.extraGroups = lib.mkAfter [ "media-library" ];

  systemd.services.audiobookshelf = {
    after = [
      "app-state-migration-v1.service"
      "audiobookshelf-storage-migration-v1.service"
      "data-pool-layout.service"
    ];
    wants = [
      "app-state-migration-v1.service"
      "audiobookshelf-storage-migration-v1.service"
      "data-pool-layout.service"
    ];
    serviceConfig.WorkingDirectory = lib.mkForce dataDir;
  };

  systemd.tmpfiles.rules = [ ];
}
