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
  };
}
