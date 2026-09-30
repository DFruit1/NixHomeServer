{ pkgs, useVulkan ? false }:
let
  # Qwen3.8-Flash-Next (qwen4exp) MTP is not in mainline yet. This pins
  # danielhanchen/llama.cpp at the head of the branch behind upstream PR #28243
  # ("models: Qwen3.8-Flash-Next MTP"), rebased on current master and the route
  # Unsloth documents for the MTP draft heads. It is mainline plus the NextN/MTP
  # graph, so it still builds every other architecture. Revert the URL to
  # ggml-org/llama.cpp once #28243 merges.
  revision = "6fcaa16f4b360649933a54d1f91ad40ed35c0e11";
  source = pkgs.fetchzip {
    url = "https://github.com/danielhanchen/llama.cpp/archive/${revision}.tar.gz";
    hash = "sha256-YgIkYHiV1LNA1OvTcB8SSdOeqr37+cEFAOQjEBfXcK4=";
  };
  baseRuntime =
    pkgs.callPackage "${source}/.devops/nix/package.nix" {
      llamaVersion = revision;
      useBlas = true;
      useCuda = false;
      useMetalKit = false;
      useRocm = false;
      inherit useVulkan;
      useWebUi = true;
    };
  runtime = baseRuntime.overrideAttrs (old: {
      # Building from the source root makes LLAMA_STANDALONE default ON, which
      # turns on tests, examples, and the unified `llama` app. Only
      # llama-server (under tools) and its mtmd/multimodal dependency are
      # needed here. The upstream UI is built from the pinned Nix webui
      # derivation and served by the authenticated AI route.
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [
        "-DLLAMA_BUILD_APP=OFF"
        "-DLLAMA_BUILD_EXAMPLES=OFF"
        "-DLLAMA_BUILD_TESTS=OFF"
        # Build every CPU backend variant as a loadable module so ggml selects
        # the best available kernels (AVX2/FMA on the Zen 3 CPU) at runtime.
        # Without this the generic x86-64 baseline (SSE2) is used, which makes
        # CPU-side MoE expert evaluation dramatically slower and is independent
        # of whichever host performs the build.
        "-DGGML_BACKEND_DL=ON"
        "-DGGML_CPU_ALL_VARIANTS=ON"
      ];
    });
in { inherit runtime revision; webui = baseRuntime.webui; }
