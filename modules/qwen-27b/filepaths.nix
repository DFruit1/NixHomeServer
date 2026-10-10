{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.qwen27b;
in
{
  options.repo.qwen27b.paths = {
    root = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/qwen-27b";
      description = ''
        Data-pool root for Qwen3.8-27B state and downloaded artifacts. The
        IQ4_XS weights are roughly 14.4 GiB, so they live on the data pool
        rather than the system SSD.
      '';
    };

    models = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwen27b.paths.root}/models";
      description = "Directory containing the hash-verified GGUF artifacts.";
    };

    modelFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwen27b.paths.models}/${config.repo.qwen27b.model.mainFile}";
      readOnly = true;
      description = "Language-model GGUF passed to llama-server as --model.";
    };

    projectorFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwen27b.paths.models}/${config.repo.qwen27b.model.projectorFile}";
      readOnly = true;
      description = "Multimodal projector GGUF used for image input.";
    };

    mtpFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwen27b.paths.models}/${config.repo.qwen27b.model.mtpFile}";
      readOnly = true;
      description = "MTP (NextN) draft head GGUF used for self-speculative decoding; only fetched when mtp.enable is true.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [
      "qwen-27b-storage-layout-v1"
      "qwen-27b-model-prepare"
      "qwen-27b-llama"
    ];

    systemd.services.qwen-27b-storage-layout-v1 = {
      description = "Provision Qwen3.8-27B data-pool layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "qwen-27b-model-prepare.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RequiresMountsFor = [ vars.dataRoot ];
      };
      script = ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/install -d -m 0750 -o qwen-27b -g qwen-27b ${lib.escapeShellArg cfg.paths.root}
        ${pkgs.coreutils}/bin/install -d -m 0750 -o qwen-27b -g qwen-27b ${lib.escapeShellArg cfg.paths.models}
      '';
    };
  };
}
