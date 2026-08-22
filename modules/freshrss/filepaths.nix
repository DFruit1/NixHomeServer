{ lib, ... }:

{
  options.repo.freshrss.stateDir = lib.mkOption {
    type = lib.types.str;
    default = "/var/lib/freshrss";
    readOnly = true;
    description = "Persistent FreshRSS configuration, user settings, subscriptions, and databases.";
  };
}
