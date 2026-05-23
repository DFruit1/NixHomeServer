{ vars, ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "kavita";
        component = "app";
        stateRoot = "/var/lib/kavita";
        payloadRoots = [
          vars.sharedBooksRoot
          vars.usersRoot
        ];
        notes = "Library database, local users, and server settings.";
      }
    ];
  };
}
