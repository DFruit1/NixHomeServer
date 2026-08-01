{ ... }:

{
  # Preserve Attic's database, cache metadata, key material, and generated Nix
  # configuration while excluding only the reproducible NAR object storage.
  repo.backups.rebuildableSnapshotPaths = [ "var/lib/atticd/storage" ];
}
