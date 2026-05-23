{ config, vars, ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "filestash";
        component = "app";
        stateRoot = config.repo.files.paths.stateDir;
        payloadRoots = [
          vars.usersRoot
          vars.sharedRoot
        ];
        notes = "Filestash config, generated local secrets, and application state.";
      }
    ];
  };
}
