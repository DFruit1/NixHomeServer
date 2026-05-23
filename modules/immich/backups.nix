{ config, ... }:

let
  paths = config.repo.immich.paths;
in
{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "immich";
          component = "app";
          stateRoot = "/var/lib/immich";
          payloadRoots = [ paths.root ];
          notes = "Immich service state directory.";
        }
        {
          app = "immich";
          component = "postgresql";
          stateRoot = config.services.postgresql.dataDir;
          payloadRoots = [ paths.managed ];
          notes = "PostgreSQL cluster; logical dump also lands in dumps/postgresql.sql.";
        }
        {
          app = "immich";
          component = "redis";
          stateRoot = config.services.redis.servers.immich.settings.dir;
          payloadRoots = [ paths.managed ];
          notes = "Immich Redis persistence.";
        }
      ];
      criticalPaths = [
        paths.root
        paths.managed
      ];
      pathInventories = [
        {
          label = "immich";
          root = paths.root;
        }
      ];
    };
  };
}
