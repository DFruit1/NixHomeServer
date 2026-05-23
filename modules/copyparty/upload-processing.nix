{ config, lib, pkgs, vars, ... }:

let
  uploadSecurity = vars.uploadSecurity;
  lowRiskExtensions = lib.concatStringsSep " " uploadSecurity.lowRiskExtensions;
  highRiskExtensions = lib.concatStringsSep " " uploadSecurity.highRiskExtensions;
  processorEnvironment = {
    UPLOAD_STAGING_ROOT = uploadSecurity.stagingRoot;
    UPLOAD_USERS_ROOT = vars.usersRoot;
    UPLOAD_QUARANTINE_ROOT = uploadSecurity.quarantineRoot;
    UPLOAD_PROCESSOR_STATE_DB = "/var/lib/upload-processor/state.sqlite";
    UPLOAD_PROCESSOR_QUEUE_DIR = "/run/upload-processor/queue";
    UPLOAD_VIRUSTOTAL_API_KEY_FILE = config.age.secrets.virusTotalApiKey.path;
    UPLOAD_SCAN_SETTLE_SECONDS = toString uploadSecurity.scanSettleSeconds;
    UPLOAD_CLAMAV_TIMEOUT_SECONDS = toString uploadSecurity.clamavTimeoutSeconds;
    UPLOAD_VIRUSTOTAL_TIMEOUT_SECONDS = toString uploadSecurity.virusTotalTimeoutSeconds;
    UPLOAD_VIRUSTOTAL_MALICIOUS_THRESHOLD = toString uploadSecurity.virusTotalMaliciousThreshold;
    UPLOAD_VIRUSTOTAL_SUSPICIOUS_THRESHOLD = toString uploadSecurity.virusTotalSuspiciousThreshold;
    UPLOAD_LOW_RISK_EXTENSIONS = lowRiskExtensions;
    UPLOAD_HIGH_RISK_EXTENSIONS = highRiskExtensions;
  } // config.services.uploadProcessor.extraEnvironment;
  processorReadWritePaths = [
    uploadSecurity.stagingRoot
    uploadSecurity.quarantineRoot
    vars.usersRoot
    "/var/lib/upload-processor"
    "/run/upload-processor"
  ] ++ config.services.uploadProcessor.extraReadWritePaths;
  processorReadOnlyPaths = [
    config.age.secrets.virusTotalApiKey.path
    "/run/clamav"
  ] ++ config.services.uploadProcessor.extraReadOnlyPaths;
  uploadProcessorPackage = pkgs.writeShellApplication {
    name = "upload-processor";
    runtimeInputs = (with pkgs; [
      bash
      clamav
      coreutils
      curl
      findutils
      gawk
      gnugrep
      gnused
      jq
      sqlite
      systemd
      util-linux
    ]) ++ config.services.uploadProcessor.extraRuntimeInputs;
    text = builtins.readFile ../../scripts/helpers/upload-processor.sh;
  };
  enqueueScript = pkgs.writeShellApplication {
    name = "upload-processor-enqueue";
    runtimeInputs = with pkgs; [
      coreutils
      jq
      systemd
    ];
    text = ''
      set -euo pipefail

      staging_root=${lib.escapeShellArg uploadSecurity.stagingRoot}
      queue_dir=/run/upload-processor/queue

      payload="''${1:-}"
      if [[ -z "$payload" ]]; then
        exit 0
      fi

      path="$(jq -r '.path // .ap // empty' <<<"$payload" 2>/dev/null || true)"
      if [[ -z "$path" ]]; then
        exit 0
      fi

      canonical_path="$(realpath -m -- "$path")"
      canonical_root="$(realpath -m -- "$staging_root")"
      if [[ "$canonical_path" != "$canonical_root"/* ]]; then
        exit 0
      fi

      install -d -m 0770 -o upload-processor -g upload-staging "$queue_dir"
      job_file="$(mktemp "$queue_dir/job.XXXXXX.json")"
      jq -c \
        --arg path "$canonical_path" \
        --arg receivedAt "$(date --iso-8601=seconds)" \
        '. + {path:$path, receivedAt:$receivedAt}' <<<"$payload" >"$job_file"
      chown upload-processor:upload-staging "$job_file" || true
      chmod 0660 "$job_file" || true

      systemctl --no-block start upload-processor.service >/dev/null 2>&1 || true
      exit 0
    '';
  };
in
{
  options.services.uploadProcessor = {
    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for upload processor integrations.";
    };

    extraReadWritePaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra read-write paths for upload processor integrations.";
    };

    extraReadOnlyPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra read-only paths for upload processor integrations.";
    };

    extraRuntimeInputs = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      description = "Extra runtime packages for upload processor integrations.";
    };
  };

  config = {
    environment.systemPackages = [
      enqueueScript
      uploadProcessorPackage
    ];

    services.clamav = {
      daemon = {
        enable = true;
        settings = {
          AlertEncrypted = true;
          AlertEncryptedArchive = true;
          AlertEncryptedDoc = true;
        };
      };
      updater.enable = true;
    };

    systemd.services.clamav-daemon.serviceConfig.MemoryMax = vars.resourceLimits.clamav.memoryMax;

    systemd.services.upload-processor = {
      description = "Scan and promote staged Copyparty uploads";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "clamav-daemon.service"
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
        "local-fs.target"
        "upload-processor-runtime-layout.service"
      ];
      after = [
        "clamav-daemon.service"
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
        "local-fs.target"
        "upload-processor-runtime-layout.service"
      ];
      path = [ uploadProcessorPackage ];
      environment = processorEnvironment;
      serviceConfig = {
        Type = "simple";
        User = "upload-processor";
        Group = "upload-processor";
        ExecStart = "${uploadProcessorPackage}/bin/upload-processor daemon";
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "upload-processor";
        StateDirectoryMode = "0750";
        UMask = "0007";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RemoveIPC = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        AmbientCapabilities = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
        ];
        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
        ];
        ReadWritePaths = processorReadWritePaths;
        ReadOnlyPaths = processorReadOnlyPaths;
      };
    };

    systemd.services.upload-processor-rescan = {
      description = "Ask upload processor to rescan staged uploads";
      wants = [
        "clamav-daemon.service"
        "data-pool-layout.service"
        "local-fs.target"
        "upload-processor-runtime-layout.service"
      ];
      after = [
        "clamav-daemon.service"
        "data-pool-layout.service"
        "local-fs.target"
        "upload-processor-runtime-layout.service"
      ];
      environment = processorEnvironment;
      serviceConfig = {
        Type = "oneshot";
        User = "upload-processor";
        Group = "upload-processor";
        UMask = "0007";
        AmbientCapabilities = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
        ];
        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_FOWNER"
        ];
        ReadWritePaths = processorReadWritePaths;
        ReadOnlyPaths = processorReadOnlyPaths;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
      path = [ uploadProcessorPackage ];
      script = ''
        ${uploadProcessorPackage}/bin/upload-processor once
      '';
    };

    systemd.timers.upload-processor-rescan = {
      description = "Periodic upload processor rescan";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2m";
        OnUnitActiveSec = uploadSecurity.rescanInterval;
        Unit = "upload-processor-rescan.service";
      };
    };
  };
}
