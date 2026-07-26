{ appPackages, config, lib, vars, ... }:

let
  cfg = config.repo.mkvmaker;
  package = appPackages.mkvmaker;
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  command = lib.escapeShellArgs [
    "${package}/bin/mkvmaker-auto-import"
    "--input-dir"
    cfg.paths.dvdInbox
    "--movies-dir"
    cfg.paths.moviesOutput
    "--shows-dir"
    cfg.paths.showsOutput
    "--state-dir"
    "${cfg.paths.stateRoot}/state"
    "--progress-file"
    "/run/mkvmaker/progress.json"
    "--converter"
    "${package}/bin/disc-to-jellyfin"
    "--settle-seconds"
    (toString cfg.settleSeconds)
    "--min-duration"
    (toString cfg.minimumTitleSeconds)
    "--dominant-ratio"
    (toString cfg.dominantTitleRatio)
    "--metadata-timeout"
    (toString cfg.metadataTimeoutSeconds)
    "--max-attempts"
    (toString cfg.maxAttempts)
    "--retry-seconds"
    (toString cfg.retrySeconds)
    "--profile"
    cfg.audioProfile
    "--video-preset"
    cfg.videoPreset
  ];
in
{
  options.repo.mkvmaker = {
    settleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 60;
      description = "Seconds an ISO must remain unchanged before it is eligible for conversion.";
    };
    minimumTitleSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 300;
      description = "Minimum DVD title duration included in automatic multi-title conversion.";
    };
    dominantTitleRatio = lib.mkOption {
      type = lib.types.float;
      default = 0.85;
      description = "Rip only the longest title when it accounts for at least this share of substantial runtime.";
    };
    metadataTimeoutSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Timeout for best-effort TVmaze metadata requests.";
    };
    maxAttempts = lib.mkOption {
      type = lib.types.ints.positive;
      default = 3;
      description = "Conversion failures allowed before preserving an ISO in the _Failed directory.";
    };
    retrySeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 900;
      description = "Base delay between retries; multiplied by the current attempt number.";
    };
    audioProfile = lib.mkOption {
      type = lib.types.enum [ "standard" "compatible" "archive" ];
      default = "standard";
      description = "disc-to-jellyfin audio profile.";
    };
    videoPreset = lib.mkOption {
      type = lib.types.enum [ "balanced" "compact" "maximum" "fast" ];
      default = "balanced";
      description = "disc-to-jellyfin x264 quality preset.";
    };
  };

  config = {
    assertions = [
      {
        assertion = cfg.dominantTitleRatio >= 0.5 && cfg.dominantTitleRatio <= 1.0;
        message = "repo.mkvmaker.dominantTitleRatio must be between 0.5 and 1.0.";
      }
    ];

    repo.storage.dataPool.guardedServices = [ "mkvmaker-import" ];

    systemd.timers.mkvmaker-import = {
      description = "Check the shared DVD ISO inbox for settled uploads";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "1min";
        OnUnitInactiveSec = "1min";
        AccuracySec = "10s";
        Persistent = true;
        Unit = "mkvmaker-import.service";
      };
    };

    systemd.services.mkvmaker-import = {
      description = "Convert settled shared DVD ISOs into Jellyfin-ready MKVs";
      requires = [ "mkvmaker-storage-layout-v1.service" ];
      wants = [ "network-online.target" ];
      after = [ "mkvmaker-storage-layout-v1.service" "network-online.target" ];
      environment = {
        HOME = cfg.paths.stateRoot;
        XDG_CONFIG_HOME = "${cfg.paths.stateRoot}/config";
        XDG_CACHE_HOME = "${cfg.paths.stateRoot}/cache";
        XDG_STATE_HOME = "${cfg.paths.stateRoot}/state";
      };
      unitConfig = {
        RequiresMountsFor = [ vars.dataRoot ];
        StartLimitIntervalSec = "1h";
        # The empty-inbox check is expected to start once per minute. Keep the
        # rate limit above that normal cadence so it only catches a genuine
        # rapid start loop instead of permanently exhausting the watcher.
        StartLimitBurst = 120;
      };
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "mkvmaker";
        RuntimeDirectoryMode = "0755";
        User = "mkvmaker";
        Group = "mkvmaker";
        SupplementaryGroups = [ sharedAccessGroup "nixhomeserver-maintenance" ];
        ExecStart = command;
        Restart = "no";
        TimeoutStartSec = "infinity";
        TimeoutStopSec = "2min";
        KillSignal = "SIGINT";
        KillMode = "control-group";
        SendSIGKILL = true;
        FinalKillSignal = "SIGKILL";
        SuccessExitStatus = [ 130 "SIGINT" ];
        UMask = "0002";
        Nice = 10;
        CPUWeight = 25;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
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
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallArchitectures = "native";
        ReadWritePaths = [
          cfg.paths.stateRoot
          cfg.paths.dvdInbox
          cfg.paths.moviesOutput
          cfg.paths.showsOutput
        ];
      };
    };
  };
}
