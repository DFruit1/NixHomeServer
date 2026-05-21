{ config, lib, ... }:

let
  fp = config.repo.apps.kavita.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.kavita.enable {
    repo.backups.appStateEntries = [
      {
        app = "kavita";
        component = "app";
        stateRoot = fp.state;
        payloadRoots = [
          fp.sharedRoots.books
          fp.userRoots.personal
        ];
        notes = "Library database, local users, and server settings.";
      }
    ];
  };
}
