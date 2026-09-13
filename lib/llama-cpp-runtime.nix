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
      useWebUi = false;
    };
  runtime = baseRuntime.overrideAttrs (old: {
      # The upstream expression still evaluates the npm-built Web UI as a
      # derivation attribute even when useWebUi is false. Severing that
      # reference avoids hundreds of irrelevant npm fetch derivations for this
      # loopback, API-only deployment.
      webui = null;
      # Building from the source root makes LLAMA_STANDALONE default ON, which
      # turns on tests, examples, the unified `llama` app, and the prebuilt-UI
      # download. Only llama-server (under tools) and its mtmd/multimodal
      # dependency are needed here; the rest either wastes build time or, for
      # the prebuilt UI, requires network access the Nix sandbox does not have.
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [
        "-DLLAMA_BUILD_APP=OFF"
        "-DLLAMA_BUILD_EXAMPLES=OFF"
        "-DLLAMA_BUILD_TESTS=OFF"
        "-DLLAMA_BUILD_UI=OFF"
        "-DLLAMA_USE_PREBUILT_UI=OFF"
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
