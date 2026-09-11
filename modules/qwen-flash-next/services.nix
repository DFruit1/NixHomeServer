{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.qwenFlashNext;
  autoContextScript = ''
    if [[ ${toString cfg.contextSize} -gt 0 ]]; then
      context_size=${toString cfg.contextSize}
    else
      memory_kib="$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)"
      memory_gib="$((memory_kib / 1048576))"
      if ((memory_gib <= 11)); then
        context_size=8192
      elif ((memory_gib <= 23)); then
        context_size=16384
      elif ((memory_gib <= 35)); then
        context_size=32768
      elif ((memory_gib <= 71)); then
        context_size=65536
      else
        context_size=131072
      fi
    fi
  '';
  server = pkgs.writeShellApplication {
    name = "qwen-flash-next-llama-server";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      set -euo pipefail

      ${autoContextScript}
      echo "Starting Qwen3.8-Flash-Next with context size $context_size (backend ${cfg.runtime.backend})"

      exec ${cfg.runtime.package}/bin/llama-server \
        --model ${lib.escapeShellArg cfg.paths.modelFile} \
        --mmproj ${lib.escapeShellArg cfg.paths.projectorFile} \
        --alias ${lib.escapeShellArg cfg.modelName} \
        --host ${lib.escapeShellArg cfg.listenAddress} \
        --port ${toString cfg.port} \
        --ctx-size "$context_size" \
        --parallel ${toString cfg.parallel} \
        --n-gpu-layers ${lib.escapeShellArg cfg.gpuLayers} \
        ${lib.optionalString cfg.cpuMoe "--cpu-moe"} \
        --flash-attn ${if cfg.flashAttention then "on" else "off"} \
        --jinja \
        --temp ${toString cfg.temperature} \
        --top-p ${toString cfg.topP} \
        --top-k 20 \
        --min-p 0 \
        --repeat-penalty ${toString cfg.repetitionPenalty} \
        ${lib.optionalString (cfg.imageMaxTokens > 0) "--image-max-tokens ${toString cfg.imageMaxTokens}"} \
        ${lib.optionalString cfg.quantizeKvCache "--cache-type-k q4_0 --cache-type-v q4_0"} \
        ${lib.escapeShellArgs cfg.extraArgs}
    '';
  };
in
{
  options.repo.qwenFlashNext = {
    contextSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = ''
        Context tokens per request. Zero selects a conservative physical-RAM
        tier automatically; the model supports up to 262144.
      '';
    };

    parallel = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Number of concurrent inference slots.";
    };

    gpuLayers = lib.mkOption {
      type = lib.types.str;
      default = if cfg.gpu.enable then "auto" else "0";
      description = ''
        Value passed to --n-gpu-layers. "auto" lets llama.cpp offload as many
        layers as fit in VRAM; "0" is CPU-only. With the 24 GB Arc Pro B60 and
        the 94 GB model, auto plus cpuMoe is the expected combination.
      '';
    };

    cpuMoe = lib.mkOption {
      type = lib.types.bool;
      default = cfg.gpu.enable;
      description = ''
        Keep all Mixture-of-Experts weights on the CPU while dense and
        attention weights use the GPU. Required to fit this model alongside a
        24 GB GPU.
      '';
    };

    flashAttention = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable llama.cpp flash attention.";
    };

    temperature = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = ''
        Default sampling temperature. Qwen3.8-Flash-Next recommends 1.0 in
        thinking mode (the model default) and 0.7 in instruct mode.
      '';
    };

    topP = lib.mkOption {
      type = lib.types.float;
      default = 0.95;
      description = ''
        Default nucleus sampling probability. The model card recommends 0.95 in
        thinking mode and 0.80 in instruct mode.
      '';
    };

    repetitionPenalty = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = ''
        Default repetition penalty (1.0 disables it). The model card recommends
        1.0 in thinking mode and 1.5 in instruct mode.
      '';
    };

    imageMaxTokens = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1024;
      description = "Maximum vision tokens per image; zero disables image downscaling.";
    };

    quantizeKvCache = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use Q4_0 KV caches to reduce long-context RAM at a small quality and speed cost.";
    };

    extraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Additional advanced llama-server command-line arguments.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.contextSize <= 262144;
        message = "repo.qwenFlashNext.contextSize cannot exceed the model's 262144-token training context.";
      }
      {
        assertion = cfg.imageMaxTokens <= 4096;
        message = "repo.qwenFlashNext.imageMaxTokens cannot exceed the model's approximate 4096 vision-token limit.";
      }
      {
        assertion = cfg.parallel == 1;
        message = "repo.qwenFlashNext.parallel is currently limited to 1 while the 94 GB model shares 128 GB of RAM with ZFS ARC.";
      }
    ];

    environment.systemPackages = [ cfg.runtime.package ];

    systemd.services.qwen-flash-next-llama = {
      description = "Qwen3.8-Flash-Next local vision-language inference API";
      wantedBy = [ "multi-user.target" ];
      wants = [ "qwen-flash-next-model-prepare.service" "qwen-flash-next-storage-layout-v1.service" ];
      requires = [ "qwen-flash-next-model-prepare.service" ];
      after = [ "qwen-flash-next-model-prepare.service" "qwen-flash-next-storage-layout-v1.service" ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 3;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "simple";
        User = "qwen-flash-next";
        Group = "qwen-flash-next";
        SupplementaryGroups = lib.optionals cfg.gpu.enable [ "render" "video" ];
        ExecStart = "${server}/bin/qwen-flash-next-llama-server";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "30min";
        TimeoutStopSec = "2min";
        OOMPolicy = "stop";
        OOMScoreAdjust = 500;
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 6;
        RequiresMountsFor = [ vars.dataRoot ];
        NoNewPrivileges = true;
        # The Vulkan backend needs access to /dev/dri, so device isolation is
        # dropped only when the GPU path is explicitly enabled.
        PrivateDevices = !cfg.gpu.enable;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        ReadOnlyPaths = [ cfg.paths.root ];
      };
    };
  };
}
