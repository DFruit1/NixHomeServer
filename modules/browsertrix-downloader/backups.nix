{ config, lib, ... }:

let
  paths = config.repo.browsertrixDownloader.paths;
in
{
  repo.backups = {
    appStateEntries = [
      {
        app = "browsertrix-downloader";
        component = "app";
        stateRoot = paths.stateRoot;
        payloadRoots = [ paths.archiveRoot paths.privateArchiveRoot ];
        notes = "Archive catalog, recipes, schedules, private profiles and resumable checkpoints, rootless crawler state, and shared/private WACZ payloads.";
      }
    ];
    criticalPaths = [ paths.archiveRoot paths.privateArchiveRoot paths.stateRoot ];
    snapshotRoots = [ paths.privateArchiveRoot ];
    sqliteDumps = [
      {
        source = "${paths.stateDir}/browsertrix-downloader.sqlite";
        outputName = "browsertrix-downloader.sqlite";
      }
    ];
  };

  # Kopia's global bulk-data policy excludes WACZ. A local policy replaces
  # its ignore list only for private originals, retaining the model exclusions.
  # Append to the existing locked, credential-bound reconciliation transaction.
  systemd.services.kopia-policy-reconcile.script = lib.mkAfter ''
    kopia policy set ${lib.escapeShellArg paths.privateArchiveRoot} --clear-ignore
    kopia policy set ${lib.escapeShellArg paths.privateArchiveRoot} \
      --add-ignore='*.gguf' --add-ignore='*.gguf.part' --max-file-size=0
  '';
}
