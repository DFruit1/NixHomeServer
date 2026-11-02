{ config, lib, vars, ... }:
{
  options.repo.transcribe = {
    stateDir = lib.mkOption { type = lib.types.str; default = "/var/lib/transcribe"; readOnly = true; };
    modelsDir = lib.mkOption { type = lib.types.str; default = "${vars.dataRoot}/transcribe/models"; readOnly = true; };
  };
  config = lib.mkIf config.repo.transcribe.enable {
    repo.storage.dataPool.guardedServices = [ "transcribe-model-prepare" "transcribe-provision" "transcribe-worker" ];
    repo.storage.userRoots.contentSubdirs = [ "_Transcribe" "_Transcripts" ];
    repo.storage.userRoots.recursiveReadonlyGrants = [ { group = "media-manager"; relativePaths = [ "_Transcribe" "_Transcripts" ]; } ];
    repo.storage.userRoots.recursiveWritableGrants = [ { group = "media-manager-broker"; relativePaths = [ "_Transcribe" "_Transcripts" ]; } ];
    systemd.tmpfiles.rules = [
      "d /var/lib/transcribe 0750 root media-manager -"
      "d /var/lib/transcribe/users 0750 root media-manager -"
      "d /var/lib/transcribe/server 0750 root root -"
      "d /var/lib/transcribe/incoming 0700 root root -"
      "d /var/lib/transcribe/incoming/parakeet 0700 root root -"
      "d /var/lib/transcribe/incoming/whisper 0700 root root -"
      "d /var/lib/transcribe/incoming/_Failed 0700 root root -"
      "d ${vars.dataRoot}/transcribe 0750 root root -"
      "d ${vars.dataRoot}/transcribe/models 0750 root root -"
      "d ${vars.dataRoot}/transcribe/work 0700 root root 7d"
    ];
  };
}
