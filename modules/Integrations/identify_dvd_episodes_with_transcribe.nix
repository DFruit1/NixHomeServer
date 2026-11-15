# mkvmaker transcribes a few minutes of each unidentified episode with the
# transcribe app's pinned Parakeet model, on the CPU (no GPU contention with
# Bonsai), to compare its dialogue with episode summaries and subtitles.
# Only read access to the one model file is granted.
{ config, lib, pkgs, ... }:
let
  transcribe = config.repo.transcribe;
  model = "${transcribe.modelsDir}/parakeet.bin";
in
{
  config = lib.mkIf transcribe.enable {
    repo.mkvmaker.identify = {
      parakeet = "${transcribe.runtime}/bin/parakeet-cli";
      parakeetModel = model;
    };
    # The model is (re)downloaded by transcribe-model-prepare, so grant
    # access after each run rather than once at activation.
    systemd.services.transcribe-model-prepare.postStart = lib.mkAfter ''
      ${pkgs.acl}/bin/setfacl -m g:mkvmaker:--x ${lib.escapeShellArg transcribe.modelsDir}
      if [ -f ${lib.escapeShellArg model} ]; then
        ${pkgs.acl}/bin/setfacl -m g:mkvmaker:r-- ${lib.escapeShellArg model}
      fi
    '';
    systemd.services.mkvmaker-import-worker = {
      wants = [ "transcribe-model-prepare.service" ];
      after = [ "transcribe-model-prepare.service" ];
    };
  };
}
