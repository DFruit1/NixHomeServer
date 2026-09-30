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
      # VRAM, the first 42 experts stay in system RAM, and speculative decoding
      # adds decode throughput. --cpu-moe is left off because --n-cpu-moe
      # supersedes it.
      qwenFlashNext = {
        enable = true;
        gpu.enable = true;
        # Hermes Agent recommends at least 64K context for tool workflows.
        contextSize = 65536;
        gpuLayers = "all";
        cpuMoe = false;
        # MTP self-speculation: the NextN head drafts tokens for the main model
        # to verify. Applied via the module so the draft path is passed with -md.
        mtp.enable = true;
        mtp.draftNMax = 4;
        # Q8_0 KV cache: near-lossless, halves KV bandwidth for long
        # generations, and frees enough VRAM for two more expert layers on the
        # Arc Pro B60 (see the n-cpu-moe change below).
        kvCacheType = "q8_0";
        extraArgs = [
          # 38 keeps only the first 38 of 48 expert layers in system RAM; the
          # Q8_0 KV cache frees enough VRAM for 10 layers on the GPU (was 6).
          # Measured: this lifts long-prompt prefill ~10% over n-cpu-moe 40.
          "--n-cpu-moe" "38"
          # With 10 expert layers on the GPU there is no room for the 904 MB
          # F16 vision projector, and llama.cpp aborts while loading it. Keep
          # the projector on the CPU; vision still works, just slower.
          "--no-mmproj-offload"
          # --load-mode none bypasses mmap for the ~51B per-layer-embedding
          # (PLE) table. On qwen4exp mmap over-reads this table and dominates
          # real-text prefill (TTFT), so keep it off. The Arc loader flags also
          # avoid host-memory staging.
          "--load-mode" "none"
          "--no-host"
          "--no-op-offload"
          # Larger micro-batches process prompt tokens with fewer weight passes.
          "--batch-size" "2048"
          "--ubatch-size" "2048"
          "--threads" "8"
          "--threads-batch" "8"
        ];
      };
    };
}
