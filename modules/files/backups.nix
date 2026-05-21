{ config, lib, ... }:

let
  fp = config.repo.apps.files.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.files.enable {
    repo.backups.appStateEntries = [
      {
        app = "filestash";
        component = "app";
        stateRoot = fp.state;
        payloadRoots = [
          fp.userRoots.personal
          fp.sharedRoots.shared
        ];
        notes = "Filestash config, generated local secrets, and application state.";
      }
    ];
  };
}
