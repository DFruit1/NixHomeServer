{ config, lib, pkgs, ... }:

let
  cfg = config.repo.bonsai;
  inherit (import ../../lib/llama-cpp-runtime.nix { inherit pkgs; useVulkan = cfg.gpu.enable;
    # Bonsai 2 needs the Hadamard activation runtime (upstream b11556+).
    revision = "cd959bae99ff4bed22bef2604f45241c09bbb8c8"; # v0.9.0
    sourceUrl = "https://github.com/ggml-org/llama.cpp/archive/cd959bae99ff4bed22bef2604f45241c09bbb8c8.tar.gz";
    sourceHash = "sha256-6LqtpfqTAbYUr/wPPBAM/dXHv3LDTg+1A81k/cFcAjY="; }) runtime revision webui;

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
      description = "Pinned mainline llama.cpp with Bonsai 2 Q2_0 Hadamard support.";
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
