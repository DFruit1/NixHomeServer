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
    lib.optionalAttrs (builtins.elem "qwen-27b" vars.enabledApps) {
      # Qwen is the server's primary local inference endpoint. It starts at
      # boot and serves Hermes and other local clients over loopback.
      #
      # The profile is tuned on this host's single 24 GiB Arc Pro B60: the
      # 16.5 GB Q4_K_M weights and the 64K Q8_0 KV cache both fit in VRAM, so
      # every layer is offloaded and nothing is left behind in system RAM for
      # the language model. Vision is the exception - the projector runs on the
      # CPU to keep the card free for weights and cache.
      qwen27b = {
        enable = true;
        gpu.enable = true;
        # Hermes Agent recommends at least 64K context for tool workflows.
        contextSize = 65536;
        gpuLayers = "all";
        # Qwen3.8-27B is dense, so there are no MoE expert tensors to keep on
        # the CPU and --cpu-moe / --n-cpu-moe have nothing to do.
        cpuMoe = false;
        # Vision on the CPU (--no-mmproj-offload): image and video input keep
        # working while VRAM stays dedicated to weights and KV cache. It also
        # moves the failure mode: vision activation buffers land in host RAM
        # against MemoryMax instead of in VRAM, which has plenty of room here.
        projectorOnCpu = true;
        # Sample video at half llama.cpp's default rate. The vision encoder
        # allocates activations per sampled frame, so this shrinks the largest
        # allocation the process can make and keeps a long video from pushing
        # it into a restart. Costs temporal detail on video QA.
        videoFps = 2.0;
        # No MTP self-speculation. Measured 15-21% slower than plain decode on
        # this host, with only 43% draft acceptance, and this pin ships no MTP
        # head for the Swift weights.
        mtp.enable = false;
        # Q8_0 KV cache: near-lossless, halves KV bandwidth for long
        # generations, and keeps the 64K context inside the card.
        kvCacheType = "q8_0";
        extraArgs = [
          # Larger micro-batches process prompt tokens with fewer passes over
          # the weights.
          "--batch-size" "2048"
          "--ubatch-size" "2048"
          "--threads" "8"
          "--threads-batch" "8"
        ];
      };
    };
}