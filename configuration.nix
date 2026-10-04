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

  repo = { }
  // lib.optionalAttrs (builtins.elem "ai-tools" vars.enabledApps) {
      # Read-only MCP tools for the llama.cpp web UI, attached per client so
      # the shared inference endpoint stays tool-free for other consumers.
      #
      # Every app-scoped `repo.<app>` block is wrapped in optionalAttrs rather
      # than assigned unconditionally. The per-app evaluation harnesses import
      # exactly one app's module, and assigning `repo.<app>.enable` at all --
      # even to `false` -- references an option that module never declared,
      # which fails evaluation rather than reading as "off".
      aiTools.enable = true;
    }
  // lib.optionalAttrs (builtins.elem "searxng" vars.enabledApps) {
      searxng.enable = true;
    }
  // lib.optionalAttrs (builtins.elem "qwen-27b" vars.enabledApps) {
      # Qwen is the server's primary local inference endpoint. It starts at
      # boot and serves Hermes and other local clients over loopback.
      #
      # The profile is tuned on this host's single 24 GiB Arc Pro B60: the
      # 16.5 GB Q4_K_M weights and the 128K Q8_0 KV cache both fit in VRAM, so
      # every layer is offloaded and nothing is left behind in system RAM for
      # the language model. Vision is the exception - the projector runs on the
      # CPU to keep the card free for weights and cache.
      qwen27b = {
        enable = true;
        gpu.enable = true;
        # Hermes Agent recommends at least 64K context for tool workflows, and
        # tool transcripts routinely overflow that, so this host runs 128K.
        #
        # Must stay equal to the local-implementer Hermes pin
        # (~/.hermes/profiles/local-implementer/config.yaml -> context_length);
        # a longer Hermes context than llama.cpp's is rejected per request, and
        # a shorter one silently truncates. Change both in the same commit.
        #
        # VRAM budget on the 23.91 GiB card, measured by loading exactly this
        # configuration on the card and reading the driver's usage counter:
        #   15.98 GiB weights (16.25 GiB file less the unused blk.64 MTP tensors)
        # +  4.25 GiB KV cache at 131072 tokens
        # +  0.86 GiB compute buffers, SSM state and Vulkan bookkeeping
        # = 21.09 GiB of 23.91 GiB, leaving 2.82 GiB free.
        # That total was read after a 12,223-token prefill, so it includes the
        # worst-case full 2048-token ubatch, not just an idle server.
        #
        # The KV term is derivable from the GGUF header and worth keeping in
        # step with any context change: qwen35, 16 full-attention layers of 64,
        # head_count_kv 4, key and value length 256, which is 34,816 B/token at
        # Q8_0's 34 B per 32 elements. 262144 would need 8.50 GiB of KV and does
        # not fit; ggml-vulkan cannot spill a failed allocation to host RAM.
        contextSize = 131072;
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
        # generations, and keeps the 128K context inside the card.
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