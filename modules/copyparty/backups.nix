{ vars, ... }:

{
  config = {
    repo.backups = {
      appStateEntries = [
        {
          app = "upload-processor";
          component = "app";
          stateRoot = "/var/lib/upload-processor";
          payloadRoots = [
            vars.uploadSecurity.stagingRoot
            vars.uploadSecurity.quarantineRoot
          ];
          notes = "Upload scan queue state, promotion ledger, staging, and quarantine metadata.";
        }
        {
          app = "copyparty";
          component = "app";
          stateRoot = "/var/lib/copyparty";
          payloadRoots = [
            vars.uploadSecurity.stagingRoot
          ];
          notes = "Local state directory for Copyparty; uploaded payloads enter locked staging before promotion.";
        }
      ];
      criticalPaths = [
        vars.uploadSecurity.stagingRoot
        vars.uploadSecurity.quarantineRoot
      ];
      pathInventories = [
        {
          label = "upload-staging";
          root = vars.uploadSecurity.stagingRoot;
        }
        {
          label = "upload-quarantine";
          root = vars.uploadSecurity.quarantineRoot;
        }
      ];
      pathRows.upload-flow-roots = [
        {
          label = "upload-staging";
          path = vars.uploadSecurity.stagingRoot;
          owner = "copyparty";
        }
        {
          label = "upload-quarantine";
          path = vars.uploadSecurity.quarantineRoot;
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
