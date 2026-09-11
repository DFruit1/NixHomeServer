{ config, lib, pkgs, ... }:

let
  cfg = config.repo.qwenFlashNext;
  # Qwen3.8-Flash-Next uses the new `qwen4exp` architecture. Support landed in
  # mainline llama.cpp after the nixpkgs channel revisions available to this
  # host, so the runtime is pinned here explicitly (the same approach the bonsai
  # module uses for its model-specific fork).
  revision = "b10897";
  source = pkgs.fetchzip {
    url = "https://github.com/ggml-org/llama.cpp/archive/${revision}.tar.gz";
    hash = "sha256-fTmHBEWosYRm+tkb5JLzpGbnhOcDjyoG65+lD1vZwt8=";
  };
  runtime =
    (pkgs.callPackage "${source}/.devops/nix/package.nix" {
      llamaVersion = revision;
      useBlas = true;
      useCuda = false;
      useMetalKit = false;
      useRocm = false;
      useVulkan = cfg.gpu.enable;
      useWebUi = false;
    }).overrideAttrs (old: {
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
in
{
  options.repo.qwenFlashNext = {
    gpu.enable = lib.mkEnableOption ''
      Vulkan GPU offload for the pinned llama.cpp build. Leave this disabled
      until the Intel Arc GPU is physically installed and the NixOS graphics
      stack has been validated on the host.
    '';

    runtime = {
      package = lib.mkOption {
        type = lib.types.package;
        default = runtime;
        readOnly = true;
        description = "Pinned mainline llama.cpp build with qwen4exp model support.";
      };

      revision = lib.mkOption {
        type = lib.types.str;
        default = revision;
        readOnly = true;
        description = "Pinned ggml-org/llama.cpp revision used for this runtime.";
      };

      backend = lib.mkOption {
        type = lib.types.enum [ "vulkan" "cpu" ];
        default = if cfg.gpu.enable then "vulkan" else "cpu";
        readOnly = true;
        description = "Inference acceleration backend compiled into the runtime.";
      };
    };
  };

  config = lib.mkIf (cfg.enable && cfg.gpu.enable) {
    # Intel Arc (Battlemage) needs the graphics stack for the Vulkan loader and
    # the mesa ANV Vulkan driver. The `xe` kernel driver (present in the 6.18
    # kernel with bmg GuC/HuC firmware) is loaded explicitly, and ReBAR must be
    # enabled in firmware for usable performance.
    boot.kernelModules = [ "xe" ];
    hardware.graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-compute-runtime
        intel-media-driver
        mesa
        vulkan-loader
        vulkan-tools
      ];
    };
  };
}
