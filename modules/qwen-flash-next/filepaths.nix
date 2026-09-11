{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.qwenFlashNext;
in
{
  options.repo.qwenFlashNext.paths = {
    root = lib.mkOption {
      type = lib.types.str;
      default = "${vars.dataRoot}/qwen-flash-next";
      description = ''
        Data-pool root for Qwen Flash Next state and downloaded artifacts. The
        model is roughly 94 GB, so it must live on the data pool rather than the
        system SSD.
      '';
    };

    models = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwenFlashNext.paths.root}/models";
      description = "Directory containing the hash-verified GGUF artifacts.";
    };

    modelFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwenFlashNext.paths.models}/${config.repo.qwenFlashNext.model.mainFile}";
      readOnly = true;
      description = "First shard of the language-model GGUF; llama.cpp loads the remaining shards automatically.";
    };

    projectorFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qwenFlashNext.paths.models}/${config.repo.qwenFlashNext.model.projectorFile}";
      readOnly = true;
      description = "Multimodal projector GGUF used for image input.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [
      "qwen-flash-next-storage-layout-v1"
      "qwen-flash-next-model-prepare"
      "qwen-flash-next-llama"
    ];

    systemd.services.qwen-flash-next-storage-layout-v1 = {
      description = "Provision Qwen Flash Next data-pool layout";
      wantedBy = [ "multi-user.target" ];
      wants = [ "data-pool-layout.service" "local-fs.target" ];
      after = [ "data-pool-layout.service" "local-fs.target" ];
      before = [ "qwen-flash-next-model-prepare.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RequiresMountsFor = [ vars.dataRoot ];
      };
      script = ''
        set -euo pipefail

        ${pkgs.coreutils}/bin/install -d -m 0750 -o qwen-flash-next -g qwen-flash-next ${lib.escapeShellArg cfg.paths.root}
        ${pkgs.coreutils}/bin/install -d -m 0750 -o qwen-flash-next -g qwen-flash-next ${lib.escapeShellArg cfg.paths.models}
      '';
    };
  };
}
