{ vars, ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "filestash";
        component = "app";
        stateRoot = vars.filesStateDir;
        payloadRoots = [
          vars.usersRoot
          vars.sharedRoot
        ];
        notes = "Filestash config, generated local secrets, and application state.";
      }
    ];
  };
}
