{ config, vars, ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "kavita";
        component = "app";
        stateRoot = "/var/lib/kavita";
        payloadRoots = [
          config.repo.kavita.paths.sharedBooksRoot
          vars.usersRoot
        ];
        notes = "Library database, local users, and server settings.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "/var/lib/kavita/config/kavita.db";
        outputName = "kavita.sqlite";
      }
    ];
  };
}
