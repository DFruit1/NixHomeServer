{ config, ... }:

{
  repo.backups.appStateEntries = [
    {
      app = "mkvmaker";
      component = "queue";
      stateRoot = config.repo.mkvmaker.paths.stateRoot;
      payloadRoots = [ ];
      notes = "Queue observations, cached title scans, encode manifests, and HandBrake logs; source ISOs and Jellyfin media remain on shared storage.";
    }
  ];
}
