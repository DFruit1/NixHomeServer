{ config, lib, pkgs, ... }:

let
  cfg = config.repo.bonsai;
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
    name = "bonsai-llama-server";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      set -euo pipefail

      ${autoContextScript}
      echo "Starting Ternary Bonsai 27B with context size $context_size"

      exec ${cfg.runtime.package}/bin/llama-server \
        --model ${lib.escapeShellArg cfg.paths.modelFile} \
        --mmproj ${lib.escapeShellArg cfg.paths.projectorFile} \
        --alias ${lib.escapeShellArg cfg.modelName} \
        --host ${lib.escapeShellArg cfg.listenAddress} \
        --port ${toString cfg.port} \
        --ctx-size "$context_size" \
        --parallel 1 \
        --n-gpu-layers 0 \
        --flash-attn on \
        --jinja \
        --temp 0.7 \
        --top-p 0.95 \
        --top-k 20 \
        --min-p 0 \
        ${lib.optionalString (cfg.imageMaxTokens > 0) "--image-max-tokens ${toString cfg.imageMaxTokens}"} \
        ${lib.optionalString cfg.quantizeKvCache "--cache-type-k q4_0 --cache-type-v q4_0"} \
        ${lib.escapeShellArgs cfg.extraArgs}
    '';
  };
in
{
  options.repo.bonsai = {
    contextSize = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 0;
      description = "Context tokens per request; zero selects PrismML's conservative physical-RAM tier automatically.";
    };

    imageMaxTokens = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 1024;
      description = "Maximum vision tokens per image on CPU; zero disables image downscaling.";
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
        message = "repo.bonsai.contextSize cannot exceed the model's 262144-token training context.";
      }
      {
        assertion = cfg.imageMaxTokens <= 4096;
        message = "repo.bonsai.imageMaxTokens cannot exceed the model's approximate 4096 vision-token limit.";
      }
    ];

    environment.systemPackages = [ cfg.runtime.package ];

    systemd.services.bonsai-llama = {
      description = "Ternary Bonsai 27B local vision-language inference API";
      wantedBy = [ "multi-user.target" ];
      requires = [ "bonsai-model-prepare.service" ];
      after = [ "bonsai-model-prepare.service" ];
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 3;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "simple";
        User = "bonsai";
        Group = "bonsai";
        ExecStart = "${server}/bin/bonsai-llama-server";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "15min";
        TimeoutStopSec = "2min";
        OOMPolicy = "stop";
        OOMScoreAdjust = 500;
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 6;
        NoNewPrivileges = true;
        PrivateDevices = true;
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
        ReadOnlyPaths = [ cfg.stateDir ];
      };
    };
  };
}
