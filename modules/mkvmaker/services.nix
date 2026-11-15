{ appPackages, config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mkvmaker;
  package = appPackages.mkvmaker;
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  command = lib.escapeShellArgs ([
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
    "--staging-dir"
    cfg.paths.stagingRoot
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
    "--worker-id"
    vars.hostname
    "--lease-seconds"
    (toString cfg.leaseSeconds)
  ] ++ lib.optionals cfg.identify.enable ([
    "--identifier"
    "${package}/bin/disc-identify"
    "--held-dir"
    cfg.paths.heldOutput
    "--needs-dir"
    cfg.paths.needsIdentification
    "--sevenzip"
    "${pkgs._7zz}/bin/7zz"
    # HandBrake's own FFmpeg build is already in the closure.
    "--ffmpeg"
    "${pkgs.handbrake.ffmpeg-hb}/bin/ffmpeg"
    "--identify-threads"
    (toString cfg.identify.threads)
  ] ++ lib.optionals (cfg.identify.bonsaiUrl != null) [ "--bonsai-url" cfg.identify.bonsaiUrl ]
    ++ lib.optionals (cfg.identify.parakeet != null) [
    "--parakeet"
    cfg.identify.parakeet
    "--parakeet-model"
    cfg.identify.parakeetModel
  ] ++ lib.optionals (cfg.identify.subtitleSocket != null) [ "--subtitle-socket" cfg.identify.subtitleSocket ]));
  dispatchCommand = "/run/current-system/sw/bin/systemctl start --no-block mkvmaker-import-worker.service";
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
    identify = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Identify TV episodes from the disc (TheDiscDB sidecar, menus) and,
          after encoding, from their dialogue. Discs that are not identified
          with certainty are held outside Jellyfin for a person to confirm.
        '';
      };
      bonsaiUrl = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "OpenAI-compatible endpoint that reads menus and ranks episode summaries; set by the Bonsai integration.";
      };
      parakeet = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "parakeet-cli used to transcribe episode excerpts on the CPU; set by the transcribe integration.";
      };
      parakeetModel = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Parakeet model file readable by the mkvmaker user.";
      };
      subtitleSocket = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Provider broker system socket that fetches episode subtitles with the uploader's OpenSubtitles account.";
      };
      threads = lib.mkOption {
        type = lib.types.ints.positive;
        default = 4;
        description = "CPU threads for transcribing excerpts.";
      };
    };
    leaseSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Seconds the importer owns an ISO before renewing its queue lease.";
    };
  };

  config = {
    # The provider broker's system socket fetches episode subtitles with the
    # uploading user's own OpenSubtitles account (never returning credentials).
    # Media Manager is a core module, so its options always exist.
    repo.mediaManager.providerSystemClients = lib.mkIf cfg.identify.enable [ "mkvmaker" ];
    repo.mkvmaker.identify.subtitleSocket =
      lib.mkIf cfg.identify.enable (lib.mkDefault config.repo.mediaManager.providerSystemSocket);

    assertions = [
      {
        assertion = (cfg.identify.parakeet == null) == (cfg.identify.parakeetModel == null);
        message = "repo.mkvmaker.identify.parakeet and parakeetModel must be set together.";
      }
      {
        assertion = cfg.dominantTitleRatio >= 0.5 && cfg.dominantTitleRatio <= 1.0;
        message = "repo.mkvmaker.dominantTitleRatio must be between 0.5 and 1.0.";
      }
    ];

    repo.storage.dataPool.guardedServices = [
      "mkvmaker-import"
      "mkvmaker-import-worker"
    ];

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
      description = "Dispatch the shared DVD ISO conversion worker";
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
        ExecStart = dispatchCommand;
        Restart = "no";
        TimeoutStartSec = "30s";
        TimeoutStopSec = "30s";
        Nice = 10;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
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
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.mkvmaker-import-worker = {
      description = "Convert settled shared DVD ISOs into Jellyfin-ready MKVs";
      wantedBy = [ "multi-user.target" ];
      requires = [ "mkvmaker-storage-layout-v1.service" ];
      wants = [ "network-online.target" ] ++ lib.optional cfg.identify.enable "media-manager-provider-broker.service";
      after = [ "mkvmaker-storage-layout-v1.service" "network-online.target" ]
        ++ lib.optional cfg.identify.enable "media-manager-provider-broker.service";
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
        Type = "simple";
        RuntimeDirectory = "mkvmaker";
        RuntimeDirectoryMode = "0755";
        # The worker is the only unit that owns /run/mkvmaker. Preserving it
        # across unit stop keeps progress.json visible to Media Manager while
        # idle instead of deleting the live status file after every run.
        RuntimeDirectoryPreserve = "yes";
        User = "mkvmaker";
        Group = "mkvmaker";
        SupplementaryGroups = [ sharedAccessGroup "nixhomeserver-maintenance" ];
        ExecStart = command;
        Restart = "on-failure";
        RestartSec = "30s";
        TimeoutStartSec = "8h";
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
          cfg.paths.heldOutput
          cfg.paths.stagingRoot
        ];
      };
    };

    # Keep the progress surface present across NixOS activation even when an
    # already-running encode crosses the generation boundary.
    systemd.tmpfiles.rules = [
      "d /run/mkvmaker 0755 mkvmaker mkvmaker -"
    ];
  };
}
