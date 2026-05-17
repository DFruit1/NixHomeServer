{ config, lib, vars, ... }:

let
  enabled = config.nixhomeserver.apps.audiobookshelf.enable;
  audiobookshelfPort = vars.networking.ports.audiobookshelf;
  dataDirName = "audiobookshelf";
in
{
  config = lib.mkIf enabled {
    services.audiobookshelf = {
      enable = true;
      dataDir = dataDirName;
      port = audiobookshelfPort;
    };

    users.users.audiobookshelf.extraGroups = lib.mkAfter [ "audiobookshelf-media" ];

    systemd.services.audiobookshelf = {
      after = [ "data-pool-layout.service" ];
      wants = [ "data-pool-layout.service" ];
      serviceConfig.WorkingDirectory = lib.mkForce "/var/lib/${config.services.audiobookshelf.dataDir}";
    };

    systemd.tmpfiles.rules = [ ];
  };
}
