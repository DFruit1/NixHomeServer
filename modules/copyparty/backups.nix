{ config, lib, ... }:

let
  fp = config.repo.apps.copyparty.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.copyparty.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "upload-processor";
          component = "app";
          stateRoot = "/var/lib/upload-processor";
          payloadRoots = [
            fp.mediaRoots.staging
            fp.mediaRoots.quarantine
          ];
          notes = "Upload scan queue state, promotion ledger, staging, and quarantine metadata.";
        }
        {
          app = "copyparty";
          component = "app";
          stateRoot = fp.state;
          payloadRoots = [
            fp.mediaRoots.staging
          ];
          notes = "Local state directory for Copyparty; uploaded payloads enter locked staging before promotion.";
        }
      ];
      criticalPaths = [
        fp.mediaRoots.staging
        fp.mediaRoots.quarantine
      ];
      pathInventories = [
        {
          label = "upload-staging";
          root = fp.mediaRoots.staging;
        }
        {
          label = "upload-quarantine";
          root = fp.mediaRoots.quarantine;
        }
      ];
      pathRows.upload-flow-roots = [
        {
          label = "upload-staging";
          path = fp.mediaRoots.staging;
          owner = "copyparty";
        }
        {
          label = "upload-quarantine";
          path = fp.mediaRoots.quarantine;
          owner = "copyparty";
        }
      ];
      sqliteDumps = [
        {
          source = "/var/lib/upload-processor/state.sqlite";
          outputName = "upload-processor-state.sqlite3";
        }
      ];
    };
  };
}
