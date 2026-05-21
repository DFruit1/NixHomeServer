{ config, lib, ... }:

let
  fp = config.repo.apps.immich.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "immich";
          component = "app";
          stateRoot = fp.state;
          payloadRoots = [ fp.data ];
          notes = "Immich service state directory.";
        }
        {
          app = "immich";
          component = "postgresql";
          stateRoot = config.services.postgresql.dataDir;
          payloadRoots = [ fp.mediaRoots.managed ];
          notes = "PostgreSQL cluster; logical dump also lands in dumps/postgresql.sql.";
        }
        {
          app = "immich";
          component = "redis";
          stateRoot = config.services.redis.servers.immich.settings.dir;
          payloadRoots = [ fp.mediaRoots.managed ];
          notes = "Immich Redis persistence.";
        }
      ];
      criticalPaths = [
        fp.data
        fp.mediaRoots.managed
      ];
      pathInventories = [
        {
          label = "immich";
          root = fp.data;
        }
      ];
    };
  };
}
