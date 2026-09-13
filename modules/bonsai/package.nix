{ config, lib, pkgs, ... }:

let
  cfg = config.repo.bonsai;
  inherit (import ../../lib/llama-cpp-runtime.nix { inherit pkgs; useVulkan = cfg.gpu.enable; }) runtime revision webui;

in
{
  options.repo.bonsai.gpu.enable = lib.mkEnableOption "Vulkan GPU acceleration";
  options.repo.bonsai.runtime = {
    webui = lib.mkOption {
      type = lib.types.package;
      default = webui;
      readOnly = true;
      description = "Upstream llama.cpp web UI built from the same pinned source.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      default = runtime;
      readOnly = true;
      description = "Pinned mainline llama.cpp with Bonsai group-64 Q2_0 support.";
    };

    revision = lib.mkOption {
      type = lib.types.str;
      default = revision;
      readOnly = true;
      description = "Mainline llama.cpp revision used for the Bonsai inference runtime.";
    };

    backend = lib.mkOption {
      type = lib.types.enum [ "cpu" "vulkan" ];
      default = if cfg.gpu.enable then "vulkan" else "cpu";
      readOnly = true;
      description = "Inference acceleration backend compiled into the current runtime.";
    };
  };

  config = lib.mkIf (cfg.enable && cfg.gpu.enable) {
    boot.kernelModules = [ "xe" ];
    hardware.graphics.enable = true;
  };
}
