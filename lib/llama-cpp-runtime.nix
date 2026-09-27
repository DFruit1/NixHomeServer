{ pkgs, useVulkan ? false }:
let
  revision = "b10897";
  source = pkgs.fetchzip {
    url = "https://github.com/ggml-org/llama.cpp/archive/${revision}.tar.gz";
    hash = "sha256-fTmHBEWosYRm+tkb5JLzpGbnhOcDjyoG65+lD1vZwt8=";
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
