{ config, ... }:

let
  cfg = config.repo.mediaManager;
in
{
  repo.backups = {
    appStateEntries = [
      {
        app = "media-manager";
        component = "control-plane";
        stateRoot = cfg.stateDir;
        payloadRoots = [ ];
        notes = "Catalog, preferences, immutable mutation plans, and permanent audit history.";
      }
      {
        app = "media-manager";
        component = "provider-accounts";
        stateRoot = cfg.providerStateDir;
        payloadRoots = [ ];
        notes = "Per-user provider account ciphertext, runtime master key, and non-secret connection health.";
      }
    ];
    sqliteDumps = [
      {
        source = "${cfg.stateDir}/control.sqlite3";
        outputName = "media-manager.sqlite3";
      }
      {
        source = "${cfg.providerStateDir}/provider-accounts.sqlite3";
        outputName = "media-manager-provider-accounts.sqlite3";
      }
    ];
  };
}
