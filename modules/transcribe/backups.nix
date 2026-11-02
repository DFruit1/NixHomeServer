{ config, lib, ... }:
{
  # State is retained in central persistence and its regular backup. Public,
  # hash-pinned models and disposable WAV scratch stay on the data pool.
  config = lib.mkIf config.repo.transcribe.enable {
    repo.backups.appStateEntries = [ {
      app = "transcribe";
      component = "jobs";
      stateRoot = config.repo.transcribe.stateDir;
      payloadRoots = [ ];
      notes = "Queue observations, personal job records and private server inbox/results. Public model weights and disposable WAV scratch are excluded.";
    } ];
  };
}
