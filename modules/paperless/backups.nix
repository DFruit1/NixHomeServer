{ config, vars, ... }:

{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "paperless";
          component = "app";
          stateRoot = "/var/lib/paperless";
          payloadRoots = [ vars.paperlessRoot ];
          notes = "Application state and local metadata.";
        }
        {
          app = "paperless";
          component = "redis";
          stateRoot = config.services.redis.servers.paperless.settings.dir;
          payloadRoots = [ vars.paperlessRoot ];
          notes = "Paperless Redis persistence.";
        }
      ];
      criticalPaths = [
        vars.paperlessRoot
        vars.paperlessInboxRoot
        vars.paperlessArchiveRoot
        vars.paperlessExportRoot
      ];
      pathInventories = [
        {
          label = "paperless";
          root = vars.paperlessRoot;
        }
      ];
      pathRows.upload-flow-roots = [
        {
          label = "paperless-inbox";
          path = vars.paperlessInboxRoot;
          owner = "paperless";
        }
        {
          label = "paperless-archive";
          path = vars.paperlessArchiveRoot;
          owner = "paperless";
        }
        {
          label = "paperless-export";
          path = vars.paperlessExportRoot;
          owner = "paperless";
        }
      ];
    };
  };
}
