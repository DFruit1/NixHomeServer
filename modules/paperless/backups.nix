{ config, ... }:

let
  paths = config.repo.paperless.paths;
in
{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "paperless";
          component = "app";
          stateRoot = "/var/lib/paperless";
          payloadRoots = [ paths.root ];
          notes = "Application state and local metadata.";
        }
        {
          app = "paperless";
          component = "redis";
          stateRoot = config.services.redis.servers.paperless.settings.dir;
          payloadRoots = [ paths.root ];
          notes = "Paperless Redis persistence.";
        }
      ];
      criticalPaths = [
        paths.root
        paths.inbox
        paths.archive
        paths.export
      ];
      pathInventories = [
        {
          label = "paperless";
          root = paths.root;
        }
      ];
      pathRows.app-content-roots = [
        {
          label = "paperless-inbox";
          path = paths.inbox;
          owner = "paperless";
        }
        {
          label = "paperless-archive";
          path = paths.archive;
          owner = "paperless";
        }
        {
          label = "paperless-export";
          path = paths.export;
          owner = "paperless";
        }
      ];
    };
  };
}
