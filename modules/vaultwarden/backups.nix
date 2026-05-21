{ config, lib, ... }:

let
  fp = config.repo.apps.vaultwarden.filepaths;
in
{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
    repo.backups.appStateEntries = [
      {
        app = "vaultwarden";
        component = "app";
        stateRoot = fp.state;
        payloadRoots = [ ];
        notes = "Encrypted password vault database and attachments.";
      }
    ];
  };
}
