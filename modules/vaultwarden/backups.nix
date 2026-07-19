{ ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "vaultwarden";
        component = "app";
        stateRoot = "/var/lib/vaultwarden";
        payloadRoots = [ ];
        notes = "Encrypted password vault database and attachments.";
      }
    ];
    repo.backups.sqliteDumps = [
      {
        source = "/var/lib/vaultwarden/db.sqlite3";
        outputName = "vaultwarden.sqlite";
      }
    ];
  };
}
