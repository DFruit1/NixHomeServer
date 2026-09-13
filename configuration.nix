{ lib, vars, ... }:

let
  catalog = import ./modules/catalog.nix;
in
{
  imports = [
    ./system-resources.nix
    ./modules/Core_Modules
  ]
  ++ map (name: catalog.apps.${name}.module) vars.enabledApps
  ++ map (entry: entry.module) (
    (import ./lib/select-integrations.nix { inherit lib; })
      catalog.integrationDefinitions
      vars.enabledApps);

  repo =
    lib.optionalAttrs (builtins.elem "bonsai" vars.enabledApps) {
      # The Bonsai server owns the web UI and the Arc GPU for interactive use.
      bonsai.gpu.enable = true;
    }
    // lib.optionalAttrs (builtins.elem "qwen-flash-next" vars.enabledApps) {
      # Qwen is reserved for background jobs; the split integration disables its
      # boot-time start so the GPU is free for the UI until a job asks for it.
      #
      # The flags below are the profile previously held by the shared router
      # preset, tuned on this host's single 24 GiB Arc Pro B60: every
      # dense/attention tensor plus the last 6 of 48 MoE expert layers live in
      # VRAM, the first 42 experts stay in system RAM, and n-gram
      # self-speculation adds decode throughput. --cpu-moe is left off because
      # --n-cpu-moe supersedes it.
      qwenFlashNext = {
        enable = true;
        gpu.enable = true;
        contextSize = 32768;
        gpuLayers = "all";
        cpuMoe = false;
        extraArgs = [
          "--n-cpu-moe" "42"
          "--spec-type" "ngram-simple"
          "--load-mode" "none"
          "--no-host"
          "--no-op-offload"
          "--threads" "8"
          "--threads-batch" "8"
        ];
      };
    };
}
