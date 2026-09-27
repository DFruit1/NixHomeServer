{ config, lib, ... }:

{
  config = lib.mkIf config.repo.ipfs.enable {
    repo.backups.appStateEntries = lib.mkAfter [
      {
        app = "ipfs";
        component = "kubo";
        stateRoot = config.repo.ipfs.paths.stateDir;
        notes = "Pinned content, node identity, and blockstore; preserve for published CIDs to remain available.";
      }
      {
        app = "ipfs";
        component = "distribution";
        stateRoot = config.repo.ipfs.paths.distributionDir;
        notes = "Stable channel pointers; restore with the Kubo state so aliases resolve.";
      }
    ];
  };
}
