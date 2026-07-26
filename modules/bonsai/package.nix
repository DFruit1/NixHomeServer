{ config, lib, pkgs, ... }:

let
  cfg = config.repo.bonsai;
  revision = "7529fdaaf99ffdc5ca71ace9c7409a56b27ad92f";
  source = pkgs.fetchzip {
    url = "https://github.com/PrismML-Eng/llama.cpp/archive/${revision}.tar.gz";
    hash = "sha256-fTPT6bo7K9Mt5ex5xMWXeUoAESa/7qqsIZGCu4RjvDE=";
  };
  runtime =
    (pkgs.callPackage "${source}/.devops/nix/package.nix" {
      llamaVersion = "prism-${builtins.substring 0 8 revision}";
      useBlas = true;
      useCuda = false;
      useMetalKit = false;
      useRocm = false;
      useVulkan = false;
      useWebUi = false;
    }).overrideAttrs (old: {
      # The fork's package expression retains the separately built Web UI as
      # a derivation attribute even when LLAMA_BUILD_WEBUI is off. Removing
      # that reference avoids hundreds of irrelevant npm fetch derivations for
      # this loopback API-only deployment.
      webui = null;
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [
        "-DLLAMA_BUILD_APP=OFF"
        "-DLLAMA_BUILD_EXAMPLES=OFF"
        "-DLLAMA_BUILD_TESTS=OFF"
        "-DLLAMA_BUILD_UI=OFF"
        "-DLLAMA_BUILD_COMMIT=${revision}"
        "-DLLAMA_BUILD_NUMBER=0"
        "-DGGML_BACKEND_DL=ON"
        "-DGGML_CPU_ALL_VARIANTS=ON"
      ];
    });
in
{
  options.repo.bonsai.runtime = {
    package = lib.mkOption {
      type = lib.types.package;
      default = runtime;
      readOnly = true;
      description = "Pinned PrismML llama.cpp build with Bonsai Q2_0 hybrid-attention and vision support.";
    };

    revision = lib.mkOption {
      type = lib.types.str;
      default = revision;
      readOnly = true;
      description = "PrismML llama.cpp revision used for the Bonsai inference runtime.";
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "cpu" ];
      default = "cpu";
      readOnly = true;
      description = "Inference acceleration backend compiled into the current runtime.";
    };
  };

  config.assertions = lib.mkIf cfg.enable [
    {
      assertion = cfg.runtime.backend == "cpu";
      message = "The current Bonsai runtime is deliberately CPU-only; add matching NixOS GPU hardware support before enabling another backend.";
    }
  ];
}
