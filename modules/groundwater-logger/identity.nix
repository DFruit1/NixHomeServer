{ config, lib, vars, ... }:

{
  config = lib.mkIf config.repo.groundwaterLogger.enable {
    users.groups.groundwater = { };
    users.users.groundwater = {
      isSystemUser = true;
      group = "groundwater";
      createHome = false;
    };

    # Retain the old identity and its SQLite archive. The Rust service uses a
    # separate identity matching the PostgreSQL role and cannot write here.
    users.groups.groundwater-logger = { };

    users.users.groundwater-logger = {
      isSystemUser = true;
      group = "groundwater-logger";
      home = "/var/lib/groundwater-logger";
      createHome = true;
    };

    services.kanidm.provision.groups.groundwater-user = {
      members = vars.kanidmAppUsers;
      overwriteMembers = false;
    };
    services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.groundwater-user =
      [ "openid" "profile" "email" "groups_name" ];
    nixhomeserver.kanidmGroupDescriptions.groundwater-user =
      "Grants read-only groundwater access to explicitly assigned devices; app-admin retains operator access.";
  };
}
