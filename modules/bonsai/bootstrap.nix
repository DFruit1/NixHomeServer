{ config, lib, pkgs, ... }:

let
  cfg = config.repo.bonsai;
  modelDir = "${cfg.stateDir}/models";
  modelFile = "${modelDir}/${cfg.model.fileName}";
  projectorFile = "${modelDir}/${cfg.model.projectorFileName}";
  resolveUrl = fileName:
    "https://huggingface.co/${cfg.model.repository}/resolve/${cfg.model.revision}/${fileName}?download=true";

  prepareModels = pkgs.writeShellApplication {
    name = "bonsai-model-prepare";
    runtimeInputs = with pkgs; [
      coreutils
      curl
    ];
    text = ''
      set -euo pipefail

      model_dir=${lib.escapeShellArg modelDir}
      mkdir -p "$model_dir"

      verify_file() {
        local expected_hash="$1"
        local target="$2"
        printf '%s  %s\n' "$expected_hash" "$target" | sha256sum --check --status
      }

      prepare_file() {
        local expected_hash="$1"
        local url="$2"
        local target="$3"
        local expected_size="$4"
        local partial="''${target}.part"

        if [[ -f "$target" ]] && verify_file "$expected_hash" "$target"; then
          echo "Verified $(basename "$target")"
          return 0
        fi

        ${lib.optionalString (!cfg.model.autoDownload) ''
          echo "Missing or invalid model artifact and automatic download is disabled: $target" >&2
          exit 1
        ''}

        if [[ -f "$partial" ]]; then
          partial_size="$(stat --format=%s "$partial")"
          if [[ "$partial_size" == "$expected_size" ]] && verify_file "$expected_hash" "$partial"; then
            mv -f -- "$partial" "$target"
            echo "Installed previously completed $(basename "$target")"
            return 0
          elif ((partial_size >= expected_size)); then
            echo "Discarding invalid completed partial artifact: $partial" >&2
            rm -f -- "$partial"
          fi
        fi

        echo "Downloading $(basename "$target") ($expected_size bytes)"
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

        actual_size="$(stat --format=%s "$partial")"
        if [[ "$actual_size" != "$expected_size" ]]; then
          echo "Downloaded artifact has unexpected size: $actual_size (expected $expected_size)" >&2
          rm -f -- "$partial"
          exit 1
        fi

        mv -f -- "$partial" "$target"
        echo "Installed $(basename "$target")"
      }

      prepare_file \
        ${lib.escapeShellArg cfg.model.sha256} \
        ${lib.escapeShellArg (resolveUrl cfg.model.fileName)} \
        ${lib.escapeShellArg modelFile} \
        ${toString cfg.model.sizeBytes}

      prepare_file \
        ${lib.escapeShellArg cfg.model.projectorSha256} \
        ${lib.escapeShellArg (resolveUrl cfg.model.projectorFileName)} \
        ${lib.escapeShellArg projectorFile} \
        ${toString cfg.model.projectorSizeBytes}
    '';
  };
in
{
  options.repo.bonsai = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to run the local Ternary Bonsai 27B vision-language model.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bonsai";
      readOnly = true;
      description = "Persistent Bonsai state and downloaded model directory.";
    };

    model = {
      repository = lib.mkOption {
        type = lib.types.str;
        default = "prism-ml/Ternary-Bonsai-27B-gguf";
        readOnly = true;
        description = "Authoritative Hugging Face GGUF repository.";
      };

      revision = lib.mkOption {
        type = lib.types.str;
        default = "abbae723028d71be674e71e1a71201a6f43fab22";
        readOnly = true;
        description = "Pinned Hugging Face repository revision containing the verified model artifacts.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "Ternary-Bonsai-27B-Q2_0.gguf";
        readOnly = true;
        description = "Official ternary Q2_0 language-model artifact.";
      };

      sha256 = lib.mkOption {
        type = lib.types.str;
        default = "868c11714cf8fe47f5ec9eeb2be0ab1a337112886f92ee0ede6b855c4fa31757";
        readOnly = true;
        description = "SHA-256 digest published by the Hugging Face LFS metadata for the model artifact.";
      };

      sizeBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 7165121600;
        readOnly = true;
        description = "Expected model artifact size.";
      };

      projectorFileName = lib.mkOption {
        type = lib.types.str;
        default = "Ternary-Bonsai-27B-mmproj-Q8_0.gguf";
        readOnly = true;
        description = "Official Q8 multimodal projector used for image input.";
      };

      projectorSha256 = lib.mkOption {
        type = lib.types.str;
        default = "eb561d41a7bbeb0fcf04883c8af11078ef6cae0a66862a0b68443cfca495269d";
        readOnly = true;
        description = "SHA-256 digest published by the Hugging Face LFS metadata for the projector.";
      };

      projectorSizeBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 629246880;
        readOnly = true;
        description = "Expected multimodal projector artifact size.";
      };

      autoDownload = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Download missing verified model artifacts from their public Hugging Face repository.";
      };
    };

    paths = {
      modelDir = lib.mkOption {
        type = lib.types.str;
        default = modelDir;
        readOnly = true;
        description = "Directory containing verified GGUF artifacts.";
      };

      modelFile = lib.mkOption {
        type = lib.types.str;
        default = modelFile;
        readOnly = true;
        description = "Verified ternary language-model path.";
      };

      projectorFile = lib.mkOption {
        type = lib.types.str;
        default = projectorFile;
        readOnly = true;
        description = "Verified multimodal projector path.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.bonsai-model-prepare = {
      description = "Download and verify Ternary Bonsai 27B model artifacts";
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ];
      unitConfig = {
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 4;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "bonsai";
        Group = "bonsai";
        ExecStart = "${prepareModels}/bin/bonsai-model-prepare";
        StateDirectory = "bonsai";
        StateDirectoryMode = "0750";
        WorkingDirectory = cfg.stateDir;
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
        ReadWritePaths = [ cfg.stateDir ];
      };
    };
  };
}
