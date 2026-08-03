{ ... }:

{
  repo.backups = {
    appStateEntries = [
      {
        app = "beszel";
        component = "hub";
        stateRoot = "/var/lib/beszel-hub";
        payloadRoots = [ ];
        notes = "Monitoring hub database, SSH key, and local dashboard state.";
      }
    ];

    sqliteDumps = [
      {
        source = "/var/lib/beszel-hub/beszel_data/data.db";
        outputName = "beszel.sqlite";
      }
    ];
  };
}
