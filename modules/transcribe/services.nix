{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.transcribe;
  worker = lib.getExe' config.repo.mediaManager.package "media-manager-transcribe";
  environment = {
    TRANSCRIBE_STATE = cfg.stateDir;
    TRANSCRIBE_USERS_ROOT = vars.usersRoot;
    TRANSCRIBE_MODELS = cfg.modelsDir;
    XDG_CACHE_HOME = "/var/cache/transcribe";
    TRANSCRIBE_SETFACL = "${pkgs.acl}/bin/setfacl";
    TRANSCRIBE_WORK_ROOT = "${vars.dataRoot}/transcribe/work";
    TRANSCRIBE_SETTLE_SECONDS = toString cfg.settleSeconds;
    TRANSCRIBE_MAX_BACKEND_WAIT = toString cfg.maxBackendWaitSeconds;
    TRANSCRIBE_FFMPEG = "${pkgs.ffmpeg}/bin/ffmpeg";
    TRANSCRIBE_FFPROBE = "${pkgs.ffmpeg}/bin/ffprobe";
    TRANSCRIBE_PARAKEET = "${cfg.runtime}/bin/parakeet-cli";
    TRANSCRIBE_WHISPER = "${cfg.runtime}/bin/whisper-cli";
    TRANSCRIBE_DIARIZATION = "${pkgs.sherpa-onnx}/bin/sherpa-onnx-offline-speaker-diarization";
  };
in {
  options.repo.transcribe = {
    settleSeconds = lib.mkOption { type = lib.types.ints.positive; default = 60; };
    maxBackendWaitSeconds = lib.mkOption { type = lib.types.ints.positive; default = 300; };
  };
  config = lib.mkIf cfg.enable {
    repo.mediaManager.integrations.transcribe = {
      available = true;
      environment.MEDIA_MANAGER_TRANSCRIBE_STATE = cfg.stateDir;
      readOnlyPaths = [ cfg.stateDir ];
    };
    systemd.services.transcribe-provision = {
      description = "Provision contained per-user transcription inboxes";
      requires = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" "fileshare-user-root-sync.service" ];
      inherit environment;
      serviceConfig = { Type = "oneshot"; ExecStart = "${worker} --provision"; PrivateNetwork = true; NoNewPrivileges = true; ProtectSystem = "strict"; ReadWritePaths = [ vars.usersRoot ]; Nice = 15; CPUWeight = 10; IOWeight = 10; MemoryHigh = "128M"; MemoryMax = "256M"; };
    };
    systemd.services.transcribe-worker = {
      description = "Transcribe settled audio with one ASR backend at a time";
      requires = [ "transcribe-provision.service" "transcribe-model-prepare.service" ];
      after = [ "transcribe-provision.service" "transcribe-model-prepare.service" ];
      inherit environment;
      unitConfig.RequiresMountsFor = [ vars.dataRoot ];
      serviceConfig = {
        Type = "oneshot"; ExecStart = worker; TimeoutStartSec = "infinity"; TimeoutStopSec = "30s";
        UMask = "0027"; PrivateNetwork = true; PrivateTmp = true;
        ProtectSystem = "strict"; ProtectHome = true; NoNewPrivileges = true;
        ProtectKernelTunables = true; ProtectKernelModules = true; ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadWritePaths = [ cfg.stateDir vars.usersRoot "${vars.dataRoot}/transcribe/work" ];
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/dri/renderD128 rw" "/dev/dri/renderD129 rw" ];
        MemoryHigh = "4G"; MemoryMax = "8G"; MemorySwapMax = 0;
        OOMPolicy = "stop"; LimitCORE = 0;
        LimitFSIZE = "4G";
        CacheDirectory = "transcribe";
        CacheDirectoryMode = "0700";
        Nice = 15; CPUWeight = 10; IOWeight = 10; TasksMax = 128;
      };
    };
    systemd.timers.transcribe-worker = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "2min"; OnUnitInactiveSec = "1min"; AccuracySec = "10s"; };
    };
    systemd.paths.transcribe-inbox = {
      wantedBy = [ "multi-user.target" ];
      pathConfig = { PathChanged = [ "${cfg.stateDir}/incoming/parakeet" "${cfg.stateDir}/incoming/whisper" ]; Unit = "transcribe-worker.service"; };
    };
  };
}
