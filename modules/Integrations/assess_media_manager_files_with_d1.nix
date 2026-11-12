{ config, lib, pkgs, vars, ... }:
let
  models = "${vars.dataRoot}/media-manager-decision/models";
  socket = "/run/media-manager-decision/d1.sock";
  revision = "4a181094d1b6addfaa3a0956f78e7ab2aa406a0c";
  artifacts = [
    { file = "d1-2B-Q8_0.gguf"; hash = "073313d92b53b0ac8193db6e906cb3c78a98183d244b15b7b8f5426115c6738c"; }
    { file = "mmproj-d1-2B-F16.gguf"; hash = "c54d0c0cc66c7e5b6b516204cab556e41d1da9e9cd970245a57d7b509af68ab3"; }
  ];
  # Reuse the mainline runtime pin already used by Bonsai, with CPU inference.
  # This revision supports LFM3 and /v1/systemone; the nixpkgs runtime predates it.
  inherit (import ../../lib/llama-cpp-runtime.nix {
    inherit pkgs;
    revision = "cd959bae99ff4bed22bef2604f45241c09bbb8c8";
    sourceUrl = "https://github.com/ggml-org/llama.cpp/archive/cd959bae99ff4bed22bef2604f45241c09bbb8c8.tar.gz";
    sourceHash = "sha256-6LqtpfqTAbYUr/wPPBAM/dXHv3LDTg+1A81k/cFcAjY=";
  }) runtime;
  prepare = pkgs.writeShellApplication {
    name = "media-manager-decision-model-prepare";
    runtimeInputs = [ pkgs.coreutils pkgs.curl ];
    text = ''
      set -euo pipefail
      cd ${lib.escapeShellArg models}
      ${lib.concatMapStringsSep "\n" (artifact: ''
        if ! printf '%s  %s\n' ${lib.escapeShellArg artifact.hash} ${lib.escapeShellArg artifact.file} | sha256sum --check --status; then
          part=$(mktemp .d1-download.XXXXXX)
          trap 'rm -f -- "$part"' EXIT
          curl --fail --location --retry 3 --connect-timeout 15 --max-time 1800 \
            ${lib.escapeShellArg "https://huggingface.co/LiquidAI/d1-2B-GGUF/resolve/${revision}/${artifact.file}"} --output "$part"
          printf '%s  %s\n' ${lib.escapeShellArg artifact.hash} "$part" | sha256sum --check --status
          chmod 0644 "$part"
          mv -- "$part" ${lib.escapeShellArg artifact.file}
          trap - EXIT
        fi
      '') artifacts}
    '';
  };
in {
  config = lib.mkIf config.services.immich.enable {
    systemd.tmpfiles.rules = [
      "d ${vars.dataRoot}/media-manager-decision 0755 root root - -"
      "d ${models} 0755 media-manager-eye media-manager-eye - -"
    ];
    systemd.services.media-manager-decision-model-prepare = {
      description = "Verify pinned Liquid d1-2B model and vision projector on the data pool";
      requires = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" "systemd-tmpfiles-setup.service" ];
      unitConfig = { ConditionPathIsMountPoint = vars.dataRoot; RequiresMountsFor = [ vars.dataRoot ]; };
      serviceConfig = {
        Type = "oneshot"; RemainAfterExit = true;
        User = "media-manager-eye"; Group = "media-manager-eye";
        ExecStart = lib.getExe prepare;
        TimeoutStartSec = "65min";
        ProtectSystem = "strict"; ProtectHome = true;
        PrivateTmp = true; NoNewPrivileges = true;
        ReadWritePaths = [ models ];
        MemoryHigh = "128M"; MemoryMax = "256M";
        Nice = 15; CPUWeight = 10; IOWeight = 10;
      };
    };
    systemd.services.media-manager-decision = {
      description = "Private local d1-2B question assessment for Media Manager";
      wantedBy = [ "multi-user.target" ];
      requires = [ "media-manager-decision-model-prepare.service" ];
      after = [ "media-manager-decision-model-prepare.service" ];
      serviceConfig = {
        DynamicUser = true;
        User = "media-manager-decision"; Group = "media-manager-provider";
        ExecStart = "${runtime}/bin/llama-server --model ${models}/d1-2B-Q8_0.gguf --mmproj ${models}/mmproj-d1-2B-F16.gguf --host ${socket} --parallel 1 --ctx-size 16384 --batch-size 8192 --ubatch-size 8192 --n-gpu-layers 0 --threads 4 --threads-batch 4 --sleep-idle-seconds 300 --no-webui --log-disable";
        RuntimeDirectory = "media-manager-decision"; RuntimeDirectoryMode = "0750";
        UMask = "0007";
        Restart = "on-failure"; RestartSec = 10;
        MemoryHigh = "5G"; MemoryMax = "6G"; MemorySwapMax = 0;
        LimitCORE = 0; Nice = 15; CPUWeight = 10; IOWeight = 10;
        NoNewPrivileges = true; PrivateTmp = true; PrivateDevices = true;
        PrivateNetwork = true;
        ProtectSystem = "strict"; ProtectHome = true;
        ProtectKernelTunables = true; ProtectKernelModules = true;
        ProtectKernelLogs = true; ProtectControlGroups = true;
        RestrictSUIDSGID = true; RestrictNamespaces = true;
        RestrictRealtime = true; LockPersonality = true;
        CapabilityBoundingSet = [ ]; RestrictAddressFamilies = [ "AF_UNIX" ];
        ReadOnlyPaths = [ models ];
        InaccessiblePaths = [ "-${config.repo.immich.paths.managed}" "-${config.repo.mediaManager.providerStateDir}" ];
      };
    };
    systemd.services.media-manager-provider-broker = {
      wants = [ "media-manager-decision.service" ];
      after = [ "media-manager-decision.service" ];
      environment.MEDIA_MANAGER_DECISION_SOCKET = socket;
    };
  };
}
