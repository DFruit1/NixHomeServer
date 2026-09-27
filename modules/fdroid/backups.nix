{ config, lib, ... }:

{
  repo.backups.appStateEntries = lib.mkAfter [
    {
      app = "fdroid";
      component = "repository";
      stateRoot = config.repo.fdroid.paths.stateDir;
      notes = "Published APKs, F-Droid metadata and the repo index signing key; keep this state backed up together.";
    }
  ];
}
