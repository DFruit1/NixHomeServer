{ config, lib, options, ... }:

let
  present = lib.hasAttrByPath [ "repo" "bonsai" ] options
    && lib.hasAttrByPath [ "repo" "qwenFlashNext" ] options;
in
{
  # The interactive UI is served by the Bonsai server only. Qwen is reserved
  # for background jobs: it does not start at boot and it has no web UI. Both
  # models share the single Arc GPU, so starting Qwen stops the UI model and a
  # small success unit restarts Bonsai when the background run finishes.
  config = lib.optionalAttrs present (
    lib.mkIf (config.repo.bonsai.enable && config.repo.qwenFlashNext.enable) {
      repo.qwenFlashNext.loadAtBoot = lib.mkDefault false;

      systemd.services.qwen-flash-next-llama = {
        conflicts = [ "bonsai-llama.service" ];
        after = [ "bonsai-llama.service" ];
        unitConfig = {
          OnSuccess = [ "bonsai-llama-restore.service" ];
          OnFailure = [ "bonsai-llama-restore.service" ];
        };
      };

      systemd.services.bonsai-llama-restore = {
        description = "Restart the Bonsai UI model and gate after a background Qwen run";
        after = [ "qwen-flash-next-llama.service" ];
        serviceConfig = {
          Type = "oneshot";
          # bonsai-gate Requires=bonsai-llama, so stopping the model also stopped
          # the gate; start both again for Paperless and interactive use.
          ExecStart = "${config.systemd.package}/bin/systemctl --no-block start bonsai-llama.service bonsai-gate.service";
        };
      };
    }
  );
}
