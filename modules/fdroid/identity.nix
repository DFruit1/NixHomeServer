{ config, ... }:

{
  users.groups.fdroidserver = { };
  users.users.fdroidserver = {
    isSystemUser = true;
    group = "fdroidserver";
    home = config.repo.fdroid.paths.stateDir;
    createHome = true;
  };
}
