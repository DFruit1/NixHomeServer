{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.qwen27b;
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
    name = "qwen-27b-llama-server";
    runtimeInputs = with pkgs; [
      coreutils
      gawk
    ];
    text = ''
      set -euo pipefail

      ${autoContextScript}
      echo "Starting Qwen3.8-27B with context size $context_size (backend ${cfg.runtime.backend})"

      exec ${cfg.runtime.package}/bin/llama-server \
        --ui \
        --path ${cfg.runtime.webui} \
        --model ${lib.escapeShellArg cfg.paths.modelFile} \
        --mmproj ${lib.escapeShellArg cfg.paths.projectorFile} \
        ${lib.optionalString cfg.projectorOnCpu "--no-mmproj-offload"} \
        ${lib.optionalString cfg.mtp.enable "--model-draft ${lib.escapeShellArg cfg.paths.mtpFile} --spec-type draft-mtp --spec-draft-n-max ${toString cfg.mtp.draftNMax}"} \
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
        ${lib.optionalString (cfg.kvCacheType != "f16") "--cache-type-k ${cfg.kvCacheType} --cache-type-v ${cfg.kvCacheType}"} \
        ${lib.escapeShellArgs cfg.extraArgs}
    '';
  };
in
{
  options.repo.qwen27b = {
    loadAtBoot = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether the loopback-only Qwen server starts with multi-user.target.
        Background consumers (for example a nightly job) can instead start the
        unit on demand and stop it afterwards to release RAM and the GPU.
      '';
    };

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
        layers as fit in VRAM; "0" is CPU-only. The Q4_K_M 27B weights fit
        entirely in the 24 GiB Arc Pro B60, so "all" is the expected value.
      '';
    };

    cpuMoe = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Keep all Mixture-of-Experts weights on the CPU while dense and
        attention weights use the GPU (--cpu-moe). Qwen3.8-27B is a dense
        model, so this is only meaningful for a future MoE sibling and is off
        by default.
      '';
    };

    projectorOnCpu = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Run the multimodal projector and vision encoder on the CPU
        (--no-mmproj-offload) instead of the GPU. Image and video input still
        works; only image encoding moves off the card, which keeps VRAM free for
        language-model layers and the 64K Q8_0 KV cache.
      '';
    };

    flashAttention = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable llama.cpp flash attention.";
    };

    mtp = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Enable Multi-Token-Prediction (NextN) self-speculative decoding. The
          server loads the Q4_0 draft head and drafts a few tokens per step
          for the main model to verify exactly. Worth roughly 1.3-2x decode on
          code and tool output, break-even on free-form prose, and is
          single-slot only. Requires a runtime with the Qwen3.8 MTP graph and
          costs 1.3 GiB of extra VRAM, so this host runs with it disabled.
        '';
      };

      draftNMax = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = ''
          Maximum tokens the MTP head drafts per step (--spec-draft-n-max).
          Higher drafts more but is accepted less often.
        '';
      };
    };

    temperature = lib.mkOption {
      type = lib.types.float;
      default = 1.0;
      description = ''
        Default sampling temperature. Qwen3.8-27B recommends 1.0 in thinking
        mode (the model default) and 0.7 in instruct mode.
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

    kvCacheType = lib.mkOption {
      type = lib.types.enum [ "f16" "q8_0" "q4_0" ];
      default = "f16";
      description = ''
        KV cache element type. Q8_0 roughly halves KV memory and bandwidth at a
        negligible quality cost and speeds up longer generations, which is what
        lets a 64K context sit in VRAM alongside the Q4_K_M weights. Q4_0 is
        smaller but noticeably lossier; F16 is the unquantized default.
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
        message = "repo.qwen27b.contextSize cannot exceed the model's 262144-token training context.";
      }
      {
        assertion = cfg.imageMaxTokens <= 4096;
        message = "repo.qwen27b.imageMaxTokens cannot exceed the model's approximate 4096 vision-token limit.";
      }
      {
        assertion = cfg.parallel == 1;
        message = "repo.qwen27b.parallel is currently limited to 1 so that the KV cache budget is not split across slots.";
      }
    ];

    environment.systemPackages = [ cfg.runtime.package ];

    systemd.services.qwen-27b-llama = {
      description = "Qwen3.8-27B local vision-language inference API";
      wantedBy = lib.optional cfg.loadAtBoot "multi-user.target";
      wants = [ "qwen-27b-model-prepare.service" "qwen-27b-storage-layout-v1.service" ];
      requires = [ "qwen-27b-model-prepare.service" ];
      after = [ "qwen-27b-model-prepare.service" "qwen-27b-storage-layout-v1.service" ];
      unitConfig = {
        RequiresMountsFor = [ vars.dataRoot ];
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 3;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      serviceConfig = {
        Type = "simple";
        User = "qwen-27b";
        Group = "qwen-27b";
        SupplementaryGroups = lib.optionals cfg.gpu.enable [ "render" "video" ];
        ExecStart = "${server}/bin/qwen-27b-llama-server";
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "30min";
        TimeoutStopSec = "2min";
        OOMPolicy = "stop";
        OOMScoreAdjust = 500;
        # The host swaps to zram with vm.swappiness=150. Compressing inference
        # working sets into zram under pressure thrashes the whole box
        # (observed: multi-second SSH stalls and ~1 tok/s inference). Forbid
        # swapping this unit so pressure is absorbed by reclaimable page cache
        # or, at worst, an OOM restart of Qwen instead of a system-wide stall.
        #
        # The caps are a runaway guard, not a working limit. The Q4_K_M weights
        # live in VRAM, so host RAM holds the mmap'd file cache, the Vulkan
        # staging and compute buffers, and the CPU-side vision encoder; measured
        # well under 32 GiB. Keeping the ceiling at 48 GiB leaves the 64 GiB ZFS
        # ARC budget reclaimable and available rather than permanently withheld.
        MemorySwapMax = "0";
        MemoryHigh = "32G";
        MemoryMax = "48G";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 6;
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
        # Under ProtectSystem=strict the Mesa/Vulkan shader cache cannot be
        # written, so every start recompiles shaders. A writable per-service
        # cache plus HOME/XDG_CACHE_HOME lets the loader persist it across
        # restarts. Only needed for the Vulkan backend.
        CacheDirectory = lib.mkIf cfg.gpu.enable "qwen-27b";
        Environment = lib.mkIf cfg.gpu.enable [
          "XDG_CACHE_HOME=/var/cache/qwen-27b"
          "HOME=/var/cache/qwen-27b"
        ];
      };
    };
  };
}
