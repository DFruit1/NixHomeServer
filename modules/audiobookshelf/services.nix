{ config, lib, vars, ... }:

let
  enabled = true;
  audiobookshelfPort = vars.networking.ports.audiobookshelf;
  dataDirName = "audiobookshelf";
in
{
  imports = [
    ./library-watch.nix
  ];

  config = {
    services.audiobookshelf = {
      enable = true;
      dataDir = dataDirName;
      port = audiobookshelfPort;
    };

    systemd.services.audiobookshelf = {
      after = [ "data-pool-layout.service" ];
      wants = [ "data-pool-layout.service" ];
      serviceConfig.WorkingDirectory = lib.mkForce "/var/lib/${config.services.audiobookshelf.dataDir}";
    };
  };
}
