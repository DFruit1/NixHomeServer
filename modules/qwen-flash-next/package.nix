{ config, lib, pkgs, ... }:

let
  cfg = config.repo.qwenFlashNext;
  inherit (import ../../lib/llama-cpp-runtime.nix { inherit pkgs; useVulkan = cfg.gpu.enable; }) runtime revision;

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
