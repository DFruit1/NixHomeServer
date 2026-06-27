{ config, lib, ... }:

{
  config = lib.mkIf config.repo.groundwaterLogger.enable {
    users.groups.groundwater-logger = {
      gid = 3003;
    };

    users.users.groundwater-logger = {
      isSystemUser = true;
      uid = 3003;
      group = "groundwater-logger";
      home = "/var/lib/groundwater-logger";
      createHome = true;
    };
  };
}
