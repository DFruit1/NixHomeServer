{ config, lib, ... }:

{
  config = lib.mkIf config.repo.seerr.enable {
    repo.backups.appStateEntries = [
      {
        app = "seerr";
        component = "app";
        stateRoot = "/var/lib/seerr";
        payloadRoots = [ ];
        notes = "Seerr request manager database and application config.";
      }
    ];
  };
}
