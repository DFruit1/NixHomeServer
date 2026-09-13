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
        --path ${cfg.runtime.webui} \
        --model ${lib.escapeShellArg cfg.paths.modelFile} \
        --mmproj ${lib.escapeShellArg cfg.paths.projectorFile} \
        --alias ${lib.escapeShellArg cfg.modelName} \
        --host ${lib.escapeShellArg cfg.listenAddress} \
        --port ${toString cfg.port} \
        --ctx-size "$context_size" \
        --parallel 1 \
        --n-gpu-layers ${if cfg.gpu.enable then "auto" else "0"} \
        --threads ${toString cfg.threads} \
        --threads-batch ${toString cfg.threadsBatch} \
        --flash-attn on \
        --jinja \
        --temp ${toString cfg.temperature} \
        --top-p ${toString cfg.topP} \
        --top-k ${toString cfg.topK} \
        --min-p ${toString cfg.minP} \
        --repeat-penalty ${toString cfg.repeatPenalty} \
        --repeat-last-n ${toString cfg.repeatLastN} \
        ${lib.optionalString (cfg.dryMultiplier > 0) "--dry-multiplier ${toString cfg.dryMultiplier} --dry-base 1.75 --dry-allowed-length 2"} \
        ${lib.optionalString (!cfg.reasoningPreserve) "--no-reasoning-preserve"} \
        ${lib.optionalString cfg.speculativeNgram "--spec-type ngram-simple"} \
        ${lib.optionalString (cfg.gpu.enable && cfg.arcLoaderFlags) "--load-mode none --no-host --no-op-offload"} \
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

    temperature = lib.mkOption {
      type = lib.types.float;
      default = 0.3;
      description = ''
        Default sampling temperature. Lowered from the model's 0.7 chat default
        because the ternary build invents terms and loops more readily at higher
        temperature, especially across multi-turn chats. Raise per request for
        creative work.
      '';
    };

    topP = lib.mkOption {
      type = lib.types.float;
      default = 0.9;
      description = "Default nucleus sampling probability.";
    };

    topK = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 20;
      description = "Default top-k sampling cutoff.";
    };

    minP = lib.mkOption {
      type = lib.types.float;
      default = 0.0;
      description = "Default min-p sampling threshold (0 disables it).";
    };

    repeatPenalty = lib.mkOption {
      type = lib.types.float;
      default = 1.1;
      description = ''
        Repetition penalty (1.0 disables it). A mild 1.1 curbs the accidental
        phrase looping seen at 1.0 without noticeably hurting output quality.
      '';
    };

    repeatLastN = lib.mkOption {
      type = lib.types.ints.unsigned;
      default = 64;
      description = "Number of recent tokens considered by --repeat-penalty.";
    };

    dryMultiplier = lib.mkOption {
      type = lib.types.float;
      default = 0.8;
      description = ''
        DRY sampling multiplier (0 disables it). DRY penalizes repeated
        sequences rather than single tokens and is the primary anti-loop lever;
        0.8 measured clean on geotechnical prose without the keyword loss that
        aggressive repetition penalties cause.
      '';
    };

    reasoningPreserve = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether prior turns' reasoning traces are kept in full history. The
        model template defaults this on, which lets old chain-of-thought
        accumulate and drift across a multi-turn chat; disabled by default so
        only the latest reasoning is retained.
      '';
    };

    threads = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = ''
        Value passed to --threads for token generation. On the Ryzen 7 5700X
        (8 cores / 16 threads) pinning to the physical core count avoids SMT
        oversubscription during decode.
      '';
    };

    threadsBatch = lib.mkOption {
      type = lib.types.ints.positive;
      default = 8;
      description = "Value passed to --threads-batch for prompt processing.";
    };

    speculativeNgram = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Enable llama.cpp n-gram self-speculation (--spec-type ngram-simple).
        Measured on this host, it is neutral-to-harmful for Bonsai: the model
        is fully GPU-resident, so it generated no drafts on prose and only
        about 2% acceptance on repetitive text, where it dropped decode from
        29.5 to 27.4 tok/s. Leave disabled unless re-measured on new hardware.
      '';
    };

    arcLoaderFlags = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        When Vulkan acceleration is enabled, add --load-mode none --no-host
        --no-op-offload to avoid host-memory staging and the slow op-offload
        path on Intel Arc. Ignored on the CPU backend.
      '';
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
        PrivateDevices = !cfg.gpu.enable;
        SupplementaryGroups = lib.optionals cfg.gpu.enable [ "render" "video" ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        # The Mesa/Vulkan shader cache otherwise fails to write under
        # ProtectSystem=strict and is disabled on every start, forcing shader
        # recompilation. CacheDirectory creates a writable per-service path;
        # pointing HOME and XDG_CACHE_HOME at it lets the loader persist the
        # cache across restarts.
        CacheDirectory = lib.mkIf cfg.gpu.enable "bonsai";
        Environment = lib.mkIf cfg.gpu.enable [
          "XDG_CACHE_HOME=/var/cache/bonsai"
          "HOME=/var/cache/bonsai"
        ];
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
