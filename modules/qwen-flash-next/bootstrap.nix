{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.qwenFlashNext;
  artifactUrl = artifact:
    "https://huggingface.co/${cfg.model.repository}/resolve/${cfg.model.revision}/"
    + lib.optionalString (artifact.subdir != "") "${artifact.subdir}/"
    + "${artifact.file}?download=true";

  prepareModels = pkgs.writeShellApplication {
    name = "qwen-flash-next-model-prepare";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      set -euo pipefail

      models_dir=${lib.escapeShellArg cfg.paths.models}
      mkdir -p "$models_dir"
      cd "$models_dir"

      verify_file() {
        printf '%s  %s\n' "$1" "$2" | sha256sum --check --status
      }

      prepare_file() {
        local file="$1"
        local url="$2"
        local expected_hash="$3"
        local expected_size="$4"
        local partial="''${file}.part"

        if [[ -f "$file" ]] && verify_file "$expected_hash" "$file"; then
          echo "Verified $file"
          return 0
        fi

        ${lib.optionalString (!cfg.model.autoDownload) ''
          echo "Missing or invalid model artifact and automatic download is disabled: $file" >&2
          exit 1
        ''}

        if [[ -f "$partial" ]]; then
          local partial_size
          partial_size="$(stat --format=%s "$partial")"
          if [[ "$partial_size" == "$expected_size" ]] && verify_file "$expected_hash" "$partial"; then
            mv -f -- "$partial" "$file"
            echo "Installed previously completed $file"
            return 0
          elif (( partial_size >= expected_size )); then
            echo "Discarding invalid completed partial artifact: $partial" >&2
            rm -f -- "$partial"
          fi
        fi

        echo "Downloading $file ($expected_size bytes)"
        curl \
          --continue-at - \
          --fail \
          --location \
          --retry 8 \
          --retry-all-errors \
          --retry-delay 10 \
          --show-error \
          --output "$partial" \
          "$url"

        if ! verify_file "$expected_hash" "$partial"; then
          echo "Downloaded artifact failed SHA-256 verification: $partial" >&2
          rm -f -- "$partial"
          exit 1
        fi

        local actual_size
        actual_size="$(stat --format=%s "$partial")"
        if [[ "$actual_size" != "$expected_size" ]]; then
          echo "Downloaded artifact has unexpected size: $actual_size (expected $expected_size)" >&2
          rm -f -- "$partial"
          exit 1
        fi

        mv -f -- "$partial" "$file"
        echo "Installed $file"
      }

      ${lib.concatMapStringsSep "\n" (artifact: ''
        prepare_file \
          ${lib.escapeShellArg artifact.file} \
          ${lib.escapeShellArg (artifactUrl artifact)} \
          ${lib.escapeShellArg artifact.sha256} \
          ${toString artifact.sizeBytes}
      '') cfg.model.artifacts}
    '';
  };
in
{
  options.repo.qwenFlashNext = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to run the local Qwen3.8-Flash-Next inference API. Disabled by
        default; enable after reviewing documentation/qwen-flash-next.md.
      '';
    };

    model = {
      repository = lib.mkOption {
        type = lib.types.str;
        default = "unsloth/Qwen3.8-Flash-Next-GGUF";
        readOnly = true;
        description = "Authoritative Hugging Face GGUF repository.";
      };

      revision = lib.mkOption {
        type = lib.types.str;
        default = "38bb39ee97821de2c9009abb7e93950eec396e66";
        readOnly = true;
        description = "Pinned Hugging Face repository revision containing the verified artifacts.";
      };

      mainFile = lib.mkOption {
        type = lib.types.str;
        default = "Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";
        readOnly = true;
        description = "First shard of the IQ4_XS language-model GGUF.";
      };

      projectorFile = lib.mkOption {
        type = lib.types.str;
        default = "mmproj-F16.gguf";
        readOnly = true;
        description = "Multimodal projector GGUF for vision input.";
      };

      autoDownload = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Download missing verified model artifacts from their public Hugging Face repository.";
      };

      artifacts = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            file = lib.mkOption { type = lib.types.str; };
            subdir = lib.mkOption {
              type = lib.types.str;
              default = "";
            };
            sha256 = lib.mkOption { type = lib.types.str; };
            sizeBytes = lib.mkOption { type = lib.types.ints.positive; };
          };
        });
        default = [
          {
            file = "Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf";
            subdir = "UD-IQ4_XS";
            sha256 = "5ce89370720f8bf90890f439361282104c1aa1482d4013bb9a50923e758e71a4";
            sizeBytes = 10946624;
          }
          {
            file = "Qwen3.8-Flash-Next-UD-IQ4_XS-00002-of-00003.gguf";
            subdir = "UD-IQ4_XS";
            sha256 = "577a38a2392b40ca2193cea502e1d92f60b8cd370675d308e0ec21885d9daaa7";
            sizeBytes = 49835229856;
          }
          {
            file = "Qwen3.8-Flash-Next-UD-IQ4_XS-00003-of-00003.gguf";
            subdir = "UD-IQ4_XS";
            sha256 = "d4634e6d84f0ebb0940be15c90d3790bf6464e3dea3a1cddc567dc0e83ad8833";
            sizeBytes = 43836407744;
          }
          {
            file = "mmproj-F16.gguf";
            sha256 = "1f7b7f0b984cf065c604360c29c8098362ed61b290db0ff12c6f360bb1a8a980";
            sizeBytes = 904004000;
          }
        ];
        description = "Hash-verified GGUF artifacts that must be present before inference starts.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.qwen-flash-next-model-prepare = {
      description = "Download and verify Qwen3.8-Flash-Next model artifacts";
      wants = [ "network-online.target" "qwen-flash-next-storage-layout-v1.service" ];
      after = [ "network-online.target" "qwen-flash-next-storage-layout-v1.service" ];
      unitConfig = {
        RequiresMountsFor = [ vars.dataRoot ];
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 4;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "qwen-flash-next";
        Group = "qwen-flash-next";
        ExecStart = "${prepareModels}/bin/qwen-flash-next-model-prepare";
        WorkingDirectory = cfg.paths.models;
        RemainAfterExit = true;
        Restart = "on-failure";
        RestartSec = "5min";
        TimeoutStartSec = "infinity";
        UMask = "0027";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        ReadWritePaths = [ cfg.paths.root ];
      };
    };
  };
}
