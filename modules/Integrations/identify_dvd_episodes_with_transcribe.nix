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
    # access after each run rather than once at activation. The app root is
    # 0750 root:root, so mkvmaker also needs to traverse it; a later tmpfiles
    # chmod only resets the ACL mask to r-x, keeping --x. The unit's sandbox
    # (ProtectSystem=strict) makes the app root read-only, so the grant runs
    # as a privileged ("+") step outside it.
    systemd.services.transcribe-model-prepare.serviceConfig.ExecStartPost = [
      "+${pkgs.writeShellScript "grant-mkvmaker-parakeet-model" ''
        set -eu
        ${pkgs.acl}/bin/setfacl -m g:mkvmaker:--x ${lib.escapeShellArg (builtins.dirOf transcribe.modelsDir)}
        ${pkgs.acl}/bin/setfacl -m g:mkvmaker:--x ${lib.escapeShellArg transcribe.modelsDir}
        if [ -f ${lib.escapeShellArg model} ]; then
          ${pkgs.acl}/bin/setfacl -m g:mkvmaker:r-- ${lib.escapeShellArg model}
        fi
      ''}"
    ];
    systemd.services.mkvmaker-import-worker = {
      wants = [ "transcribe-model-prepare.service" ];
      after = [ "transcribe-model-prepare.service" ];
    };
    # The audio CD importer transcribes spoken credits with the same model.
    systemd.services.mkvmaker-audio-import = lib.mkIf config.repo.mkvmaker.audio.enable {
      wants = [ "transcribe-model-prepare.service" ];
      after = [ "transcribe-model-prepare.service" ];
    };
  };
}
