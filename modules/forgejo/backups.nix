{ config, lib, ... }:

let
  cfg = config.repo.forgejo;
in
{
  config = lib.mkIf cfg.enable {
    repo.backups = {
      appStateEntries = [
        {
          app = "forgejo";
          component = "app";
          stateRoot = "/var/lib/forgejo";
          payloadRoots = [ ];
          notes = "Forgejo Configuration, repository Git data, LFS objects, and local accounts.";
        }
      ];
      sqliteDumps = [
        {
          source = "/var/lib/forgejo/data/forgejo.db";
          outputName = "forgejo.sqlite";
        }
      ];
    };
  };
}
