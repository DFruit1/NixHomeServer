{ config, lib, vars, appPackages, ... }:

let
  cfg = config.repo.bonsai;
  gateCfg = cfg.gate;
in
{
  options.repo.bonsai.gate = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Run the loopback ai-gate concurrency guard in front of llama-server.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = vars.networking.ports.bonsaiGate;
      description = "Loopback port the ai-gate proxy listens on; Paperless uses this, not llama-server directly.";
    };

    gateBaseUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${vars.networking.loopbackIPv4}:${toString gateCfg.port}/v1";
      readOnly = true;
      description = "Stable OpenAI-compatible base URL for local consumers behind the concurrency gate.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = appPackages.ai-gate;
      description = "Rust ai-gate proxy package.";
    };

    maxQueued = lib.mkOption {
      type = lib.types.ints.positive;
      default = 2;
      description = "Requests waiting for the single upstream slot beyond the in-flight one before 429.";
    };

    queueTimeoutSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "How long a queued request waits for the upstream slot before 504.";
    };

    upstreamTimeoutSecs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Upstream llama-server request timeout; matches the Paperless AI request timeout.";
    };

    maxBodyBytes = lib.mkOption {
      type = lib.types.ints.positive;
      default = 15728640;
      description = "Maximum proxied request body (covers vision base64 without allowing abuse).";
    };
  };

  config = lib.mkIf (cfg.enable && gateCfg.enable) {
    assertions = [
      {
        assertion = gateCfg.port != cfg.port;
        message = "repo.bonsai.gate.port must differ from repo.bonsai.port.";
      }
    ];

    systemd.services.bonsai-gate = {
      description = "Local AI concurrency gate (serializes llama-server parallel=1)";
      wantedBy = [ "multi-user.target" ];
      requires = [ "bonsai-llama.service" ];
      after = [ "bonsai-llama.service" ];
      unitConfig = {
        StartLimitIntervalSec = "5min";
        StartLimitBurst = 5;
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
      };
      environment = {
        AI_GATE_LISTEN = "${vars.networking.loopbackIPv4}:${toString gateCfg.port}";
        AI_GATE_UPSTREAM = "http://${cfg.listenAddress}:${toString cfg.port}";
        AI_GATE_MAX_INFLIGHT = "1";
        AI_GATE_MAX_QUEUED = toString gateCfg.maxQueued;
        AI_GATE_QUEUE_TIMEOUT_SECS = toString gateCfg.queueTimeoutSecs;
        AI_GATE_UPSTREAM_TIMEOUT_SECS = toString gateCfg.upstreamTimeoutSecs;
        AI_GATE_MAX_BODY_BYTES = toString gateCfg.maxBodyBytes;
      };
      serviceConfig = {
        Type = "simple";
        User = "bonsai";
        Group = "bonsai";
        ExecStart = "${gateCfg.package}/bin/ai-gate";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "1min";
        TimeoutStopSec = "30s";
        # The gate itself must never become the resource hog: tight caps so a
        # flood of Paperless suggestion clicks fails fast with 429/504 instead
        # of starving the host.
        MemoryHigh = "256M";
        MemoryMax = "512M";
        MemorySwapMax = "0";
        CPUQuota = "50%";
        CPUWeight = 10;
        IOWeight = 10;
        Nice = 10;
        OOMScoreAdjust = 500;
        NoNewPrivileges = true;
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
      };
    };
  };
}
