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
        notes = "Retained historical SQLite message log; the groundwater platform now writes PostgreSQL.";
      }
      {
        app = "groundwater-logger";
        component = "postgresql";
        stateRoot = config.services.postgresql.dataDir;
        payloadRoots = [ ];
        notes = "Groundwater observations, enrollments, device permissions and audit state; logical dump in dumps/groundwater.pgdump.";
      }
      {
        app = "groundwater-logger";
        component = "mqtt-broker";
        stateRoot = paths.brokerStateDir;
        payloadRoots = [ ];
        notes = "Mosquitto retained messages and subscription persistence for the groundwater platform.";
      }
    ];

    postgresqlDumps = [
      {
        database = "groundwater";
        user = "groundwater";
        outputName = "groundwater.pgdump";
      }
    ];
  };
}
