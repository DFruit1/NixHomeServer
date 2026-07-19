{ config, lib, ... }:

{
  config = lib.mkIf config.repo.groundwaterLogger.enable {
    users.groups.groundwater-logger = { };

    users.users.groundwater-logger = {
      isSystemUser = true;
      group = "groundwater-logger";
      home = "/var/lib/groundwater-logger";
      createHome = true;
    };
  };
}
