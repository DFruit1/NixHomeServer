{ config, vars, ... }:

{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "immich";
          component = "app";
          stateRoot = "/var/lib/immich";
          payloadRoots = [ vars.immichRoot ];
          notes = "Immich service state directory.";
        }
        {
          app = "immich";
          component = "postgresql";
          stateRoot = config.services.postgresql.dataDir;
          payloadRoots = [ vars.immichManagedRoot ];
          notes = "PostgreSQL cluster; logical dump also lands in dumps/postgresql.sql.";
        }
        {
          app = "immich";
          component = "redis";
          stateRoot = config.services.redis.servers.immich.settings.dir;
          payloadRoots = [ vars.immichManagedRoot ];
          notes = "Immich Redis persistence.";
        }
      ];
      criticalPaths = [
        vars.immichRoot
        vars.immichManagedRoot
      ];
      pathInventories = [
        {
          label = "immich";
          root = vars.immichRoot;
        }
      ];
    };
  };
}
