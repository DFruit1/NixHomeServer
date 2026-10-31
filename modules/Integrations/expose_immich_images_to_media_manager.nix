{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  models = "${vars.dataRoot}/eye/models";
  socket = "/run/media-manager-eye/eye.sock";
  runtime = pkgs.callPackage ../../custom_apps/rust/apps/media-manager/eye-runtime { };
  revision = "22f84595225252153fc8e11e7f5fba152fe13718";
  artifacts = [
    { file = "eye.tflite"; hash = "25ba485c959a47961ac9243e74e6ad4997bfc88e1267f62aa88827fc9d92894b"; }
    { file = "eye_meta.json"; hash = "3678669c840378bca191250597e3a77e5b478e12d3e70c48f827b860551f791c"; }
  ];
  prepare = pkgs.writeShellApplication {
    name = "media-manager-eye-model-prepare";
    runtimeInputs = [ pkgs.coreutils pkgs.curl ];
    text = ''
      set -euo pipefail
      cd ${lib.escapeShellArg models}
      ${lib.concatMapStringsSep "\n" (artifact: ''
        if ! printf '%s  %s\n' ${lib.escapeShellArg artifact.hash} ${lib.escapeShellArg artifact.file} | sha256sum --check --status; then
          part=$(mktemp .eye-download.XXXXXX)
          trap 'rm -f -- "$part"' EXIT
          curl --fail --location --retry 3 --connect-timeout 15 --max-time 600 \
            ${lib.escapeShellArg "https://huggingface.co/desert-ant-labs/eye/resolve/${revision}/${artifact.file}"} \
            --output "$part"
          printf '%s  %s\n' ${lib.escapeShellArg artifact.hash} "$part" | sha256sum --check --status
          chmod 0644 "$part"
          mv -- "$part" ${lib.escapeShellArg artifact.file}
          trap - EXIT
        fi
      '') artifacts}
      # Match the SDK's verified offline manifest; inference gets a read-only
      # model directory and never downloads or replaces weights itself.
      mkdir -p .dal-meta
      # A pre-existing SDK manifest can belong to the earlier interactive user.
      # Publish through our directory rather than truncating that user's file.
      manifest_tmp=$(mktemp .dal-meta/.manifest.XXXXXX)
      trap 'rm -f -- "$manifest_tmp"' EXIT
      printf 'DAL1\nR\teye.tflite\nR\teye_meta.json\nF\teye.tflite\t66038240\t25ba485c959a47961ac9243e74e6ad4997bfc88e1267f62aa88827fc9d92894b\nF\teye_meta.json\t280890\t3678669c840378bca191250597e3a77e5b478e12d3e70c48f827b860551f791c' > "$manifest_tmp"
      chmod 0755 .dal-meta
      chmod 0644 "$manifest_tmp"
      mv -- "$manifest_tmp" .dal-meta/manifest
      trap - EXIT
    '';
  };
in
{
  config = lib.mkIf config.services.immich.enable {
    repo.mediaManager.integrations.immich = {
      label = "Immich";
      available = true;
      capabilities = [ "image-library" "image-tags" ];
      url = "https://photos.${vars.domain}";
    };
    users.groups.media-manager-eye = { };
    users.users.media-manager-eye = {
      isSystemUser = true;
      group = "media-manager-eye";
    };
    systemd.tmpfiles.rules = [
      "d ${vars.dataRoot}/eye 0755 media-manager-eye media-manager-eye - -"
      "d ${models} 0755 media-manager-eye media-manager-eye - -"
      "d ${models}/.dal-meta 0755 media-manager-eye media-manager-eye - -"
    ];
    systemd.services.media-manager-eye-model-prepare = {
      description = "Verify pinned EYE weights on the data pool";
      requires = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" "systemd-tmpfiles-setup.service" ];
      unitConfig = {
        ConditionPathIsMountPoint = vars.dataRoot;
        RequiresMountsFor = [ vars.dataRoot ];
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "media-manager-eye";
        Group = "media-manager-eye";
        ExecStart = lib.getExe prepare;
        TimeoutStartSec = "15min";
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        ReadWritePaths = [ models ];
      };
    };
    systemd.services.media-manager-eye = {
      description = "Local EYE photo analysis for Media Manager";
      wantedBy = [ "multi-user.target" ];
      requires = [ "media-manager-eye-model-prepare.service" ];
      after = [ "media-manager-eye-model-prepare.service" ];
      environment = {
        MEDIA_MANAGER_EYE_SOCKET = socket;
        MEDIA_MANAGER_EYE_MODELS = models;
        SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      };
      serviceConfig = {
        Type = "simple";
        User = "media-manager-eye";
        # The credential broker may connect to this socket, but cannot access
        # the helper's private cache or any Immich filesystem/database.
        Group = "media-manager-provider";
        ExecStart = lib.getExe runtime;
        RuntimeDirectory = "media-manager-eye";
        RuntimeDirectoryMode = "0750";
        CacheDirectory = "media-manager-eye";
        CacheDirectoryMode = "0700";
        Environment = [ "XDG_CACHE_HOME=/var/cache/media-manager-eye" "HOME=/var/cache/media-manager-eye" ];
        UMask = "0007";
        Restart = "on-failure";
        RestartSec = 5;
        MemoryHigh = "2G";
        MemoryMax = "3G";
        MemorySwapMax = 0;
        CPUWeight = 20;
        Nice = 10;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictRealtime = true;
        LockPersonality = true;
        CapabilityBoundingSet = [ ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        ReadOnlyPaths = [ models ];
        InaccessiblePaths = [ "-${config.repo.immich.paths.managed}" "-${cfg.providerStateDir}" ];
      };
    };
    systemd.services.media-manager-provider-broker = {
      wants = [ "media-manager-eye.service" ];
      after = [ "media-manager-eye.service" ];
      environment = {
        MEDIA_MANAGER_IMMICH_API_BASE = "http://${config.services.immich.host}:${toString config.services.immich.port}/api/";
        MEDIA_MANAGER_EYE_SOCKET = socket;
        MEDIA_MANAGER_EDITOR_GROUP = cfg.editorGroup;
        MEDIA_MANAGER_MUTATION_MODE = cfg.mutationMode;
      };
      serviceConfig.RestrictAddressFamilies = [ "AF_UNIX" ];
    };
  };
}
