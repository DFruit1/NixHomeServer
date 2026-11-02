{ config, lib, pkgs, ... }:
{
  options.repo.transcribe.runtime = lib.mkOption {
    type = lib.types.package;
    # The channel's 1.8.4 lacks Parakeet. Pin both CLI output contracts together.
    default = (pkgs.whisper-cpp.override { vulkanSupport = true; withSDL = false; }).overrideAttrs (_: {
      version = "1.9.5";
      src = pkgs.fetchzip {
        url = "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz";
        hash = "sha256-Qqqpt+pvCQwSbyaBr1bdb7q+3LbELTcloHdiSikGPc4=";
      };
      patches = [ ];
      postPatch = ""; # Targets install themselves in 1.9.5.
    });
    description = "Pinned whisper.cpp with Vulkan and both CLI adapters.";
  };
  config = lib.mkIf config.repo.transcribe.enable {
    boot.kernelModules = [ "xe" ];
    hardware.graphics.enable = true;
    hardware.graphics.extraPackages = [ pkgs.mesa pkgs.vulkan-loader ];
  };
}
