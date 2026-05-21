{ config, lib, ... }:

let
  fp = config.repo.apps.paperless.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.paperless.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "paperless";
          component = "app";
          stateRoot = fp.state;
          payloadRoots = [ fp.data ];
          notes = "Application state and local metadata.";
        }
        {
          app = "paperless";
          component = "redis";
          stateRoot = config.services.redis.servers.paperless.settings.dir;
          payloadRoots = [ fp.data ];
          notes = "Paperless Redis persistence.";
        }
      ];
      criticalPaths = [
        fp.data
        fp.mediaRoots.inbox
        fp.mediaRoots.archive
        fp.mediaRoots.export
      ];
      pathInventories = [
        {
          label = "paperless";
          root = fp.data;
        }
      ];
      pathRows.upload-flow-roots = [
        {
          label = "paperless-inbox";
          path = fp.mediaRoots.inbox;
          owner = "paperless";
        }
        {
          label = "paperless-archive";
          path = fp.mediaRoots.archive;
          owner = "paperless";
        }
        {
          label = "paperless-export";
          path = fp.mediaRoots.export;
          owner = "paperless";
        }
      ];
    };
  };
}
