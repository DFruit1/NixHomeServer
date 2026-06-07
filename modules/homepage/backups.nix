{ ... }:

{
  config = {
    repo.backups.appStateEntries = [
      {
        app = "homepage";
        component = "app";
        stateRoot = "/var/lib/homepage";
        payloadRoots = [ ];
        notes = "Homepage service home. The rendered app content is generated declaratively from Nix configuration.";
      }
    ];
  };
}
