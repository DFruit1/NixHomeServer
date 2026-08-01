{ ... }:

{
  # Keep this exclusion while Bonsai is disabled because impermanence retains
  # the pinned, hash-verified model artifacts for a later re-enable.
  repo.backups.rebuildableSnapshotPaths = [ "var/lib/bonsai/models" ];
}
