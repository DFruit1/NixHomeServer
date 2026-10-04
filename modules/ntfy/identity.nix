{ config, lib, ... }:

let
  cfg = config.repo.ntfy;
in
{
  config = lib.mkIf cfg.enable {
    users.groups.ntfy = { };

    users.users.ntfy = {
      isSystemUser = true;
      group = "ntfy";
      home = cfg.stateDir;
      createHome = false;
    };

    # ntfy deliberately runs with no Kanidm identity at all. Topics are
    # unauthenticated by owner decision, so there is no group to provision and
    # nothing that could later be mistaken for a per-user access boundary.
  };
}