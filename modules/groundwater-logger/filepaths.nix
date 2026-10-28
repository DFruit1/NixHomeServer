{ config, lib, ... }:

let
  cfg = config.repo.groundwaterLogger;
  paths = config.repo.groundwaterLogger.paths;
in
{
  options.repo.groundwaterLogger.paths = {
    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/groundwater-logger";
      description = "Retained historical groundwater logger state root.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.groundwaterLogger.paths.stateRoot}/state";
      description = "Retained historical groundwater logger SQLite directory; not used by the Rust service.";
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.groundwaterLogger.paths.stateDir}/messages.sqlite";
      description = "Retained historical MQTT message SQLite database; never migrated or deleted automatically.";
    };

    brokerStateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/groundwater-mosquitto";
      description = "Mosquitto persistent state for the groundwater platform.";
    };
  };

  config.systemd.tmpfiles.rules = lib.mkIf cfg.enable [
    "d ${paths.stateRoot} 0750 groundwater-logger groundwater-logger -"
    "d ${paths.stateDir} 0750 groundwater-logger groundwater-logger -"
    "d ${paths.brokerStateDir} 0750 mosquitto mosquitto -"
  ];
}
