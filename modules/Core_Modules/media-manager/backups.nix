{ config, ... }:

let
  cfg = config.repo.mediaManager;
in
{
  repo.backups = {
    # Provider lookup responses are disposable and change frequently; refill
    # them from the providers instead of snapshotting up to 64 MiB per cache.
    rebuildableSnapshotPaths = [
      "var/lib/media-manager/metadata-lookups.sqlite3"
      "var/lib/media-manager/metadata-lookups.sqlite3-shm"
      "var/lib/media-manager/metadata-lookups.sqlite3-wal"
      "var/lib/media-manager-provider/lookup-cache.sqlite3"
      "var/lib/media-manager-provider/lookup-cache.sqlite3-shm"
      "var/lib/media-manager-provider/lookup-cache.sqlite3-wal"
    ];
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
