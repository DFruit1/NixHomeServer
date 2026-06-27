{ config, lib, ... }:

let
  paths = config.repo.groundwaterLogger.paths;
in
{
  config.repo.backups = lib.mkIf config.repo.groundwaterLogger.enable {
    appStateEntries = [
      {
        app = "groundwater-logger";
        component = "app";
        stateRoot = paths.stateRoot;
        payloadRoots = [ ];
        notes = "SQLite MQTT message log and groundwater logger test console state.";
      }
      {
        app = "groundwater-logger";
        component = "mqtt-broker";
        stateRoot = paths.brokerStateDir;
        payloadRoots = [ ];
        notes = "Mosquitto retained messages and subscription persistence for groundwater logger tests.";
      }
    ];

    sqliteDumps = [
      {
        source = paths.database;
        outputName = "groundwater-logger-messages.sqlite";
      }
    ];
  };
}
