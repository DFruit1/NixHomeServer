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
      # IQ4_XS 27B weights, a 192K-token Q8_0 KV cache and two parallel slots
      # all fit in VRAM, so every layer is offloaded and nothing is left behind
      # in system RAM for the language model. Vision is the exception - the
      # projector runs on the CPU to keep the card free for weights and cache.
      qwen27b = {
        enable = true;
        gpu.enable = true;
        # Two concurrent 96K sessions. Hermes Agent recommends at least 64K
        # context for tool workflows and its transcripts routinely overflow
        # that, so each of the two slots gets 96K.
        #
        # llama.cpp splits this total across `parallel` slots, so the
        # local-implementer Hermes pin
        # (~/.hermes/profiles/local-implementer/config.yaml -> context_length)
        # must equal 98304 (contextSize / parallel), NOT contextSize itself; a
        # longer Hermes context than its slot is rejected per request, and a
        # shorter one silently truncates. Change both in the same commit.
        #
        # VRAM budget on the 23.91 GiB card, scaled from the measured Q4_K_M
        # load (15.98 GiB weights, 0.86 GiB buffers at parallel = 1):
        #   ~14.2 GiB weights (IQ4_XS, 15.48 GB file less the unused blk.64
        #     MTP tensors)
        # +  6.38 GiB KV cache at 196608 tokens total (2 x 98304)
        # +  ~0.86 GiB compute buffers, SSM state and Vulkan bookkeeping, plus
        #     the second slot's per-sequence recurrent state
        # = ~21.4 GiB of 23.91 GiB, leaving about 2.5 GiB free - the same
        # safety class as the previous single 128K session (2.82 GiB). The
        # parallel = 1 buffer figure is the uncertain term: this hybrid qwen35
        # keeps a per-sequence gated-delta-net state, so two slots roughly
        # double that portion. Verify against the card before trusting it.
        #
        # The KV term is derivable from the GGUF header and worth keeping in
        # step with any context change: qwen35, 16 full-attention layers of 64,
        # head_count_kv 4, key and value length 256, which is 34,816 B/token at
        # Q8_0's 34 B per 32 elements. A 262144-token total would need 8.50 GiB
        # of KV and does not fit; ggml-vulkan cannot spill a failed allocation
        # to host RAM.
        contextSize = 196608;
        parallel = 2;
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