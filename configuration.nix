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

  # Hermes Agent's upstream installer manages generic Linux binaries such as
  # Node and FFmpeg. NixOS needs nix-ld to run those in the dsaw user profile.
  programs.nix-ld.enable = true;

  repo =
    lib.optionalAttrs (builtins.elem "qwen-flash-next" vars.enabledApps) {
      # Qwen is the server's primary local inference endpoint. It starts at
      # boot and serves Hermes and other local clients over loopback.
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
        # Hermes Agent recommends at least 64K context for tool workflows.
        contextSize = 65536;
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
