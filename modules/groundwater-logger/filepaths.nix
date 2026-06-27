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
      description = "Groundwater logger app persistent state root.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.groundwaterLogger.paths.stateRoot}/state";
      description = "Groundwater logger SQLite state directory.";
    };

    database = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.groundwaterLogger.paths.stateDir}/messages.sqlite";
      description = "Groundwater logger MQTT message SQLite database.";
    };

    brokerStateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/groundwater-mosquitto";
      description = "Mosquitto persistent state for groundwater logger tests.";
    };
  };

  config.systemd.tmpfiles.rules = lib.mkIf cfg.enable [
    "d ${paths.stateRoot} 0750 groundwater-logger groundwater-logger -"
    "d ${paths.stateDir} 0750 groundwater-logger groundwater-logger -"
    "d ${paths.brokerStateDir} 0750 mosquitto mosquitto -"
  ];
}
