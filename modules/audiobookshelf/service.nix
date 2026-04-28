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

  users.users.audiobookshelf.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];

  systemd.services.audiobookshelf = {
    after = [ "data-pool-layout.service" ];
    wants = [ "data-pool-layout.service" ];
    serviceConfig.WorkingDirectory = lib.mkForce dataDir;
  };

  systemd.tmpfiles.rules = [ ];
}
