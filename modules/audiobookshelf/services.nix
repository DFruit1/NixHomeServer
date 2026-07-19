{ config, lib, vars, ... }:

let
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
      requires = [ "data-pool-layout.service" ];
      unitConfig = lib.mkMerge [
        { RequiresMountsFor = [ vars.dataRoot ]; }
        (lib.mkIf vars.dataRootIsMountPoint {
          ConditionPathIsMountPoint = vars.dataRoot;
        })
      ];
      serviceConfig.WorkingDirectory = lib.mkForce "/var/lib/${config.services.audiobookshelf.dataDir}";
    };
  };
}
