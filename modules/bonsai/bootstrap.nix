{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.bonsai;
  modelDir = "${vars.dataRoot}/bonsai/models";
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
      description = "Whether to run the local Ternary Bonsai 2 27B vision-language model.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/bonsai";
      readOnly = true;
      description = "Persistent Bonsai metadata; model artifacts live on the data pool.";
    };

    model = {
      repository = lib.mkOption {
        type = lib.types.str;
        default = "prism-ml/Ternary-Bonsai-2-27B-gguf";
        readOnly = true;
        description = "Authoritative Hugging Face GGUF repository.";
      };

      revision = lib.mkOption {
        type = lib.types.str;
        default = "839bd57023c1558945afea70a74fa83c054f35f9";
        readOnly = true;
        description = "Pinned Hugging Face repository revision containing the verified model artifacts.";
      };

      fileName = lib.mkOption {
        type = lib.types.str;
        default = "Ternary-Bonsai-2-27B-Q2_0.gguf";
        readOnly = true;
        description = "Official ternary Q2_0 language-model artifact.";
      };

      sha256 = lib.mkOption {
        type = lib.types.str;
        default = "4f99aed01b8a877e153f9aa6569a4440fe17c59701cc0953e36d7f460549e70e";
        readOnly = true;
        description = "SHA-256 digest published by the Hugging Face LFS metadata for the model artifact.";
      };

      sizeBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 7626008928;
        readOnly = true;
        description = "Expected model artifact size.";
      };

      projectorFileName = lib.mkOption {
        type = lib.types.str;
        default = "Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf";
        readOnly = true;
        description = "Official Q8 multimodal projector used for image input.";
      };

      projectorSha256 = lib.mkOption {
        type = lib.types.str;
        default = "6807ede61d570bb86ba34b756a0fa109edc33668604de867c6ea6d8f1d631903";
        readOnly = true;
        description = "SHA-256 digest published by the Hugging Face LFS metadata for the projector.";
      };

      projectorSizeBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 629246976;
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
    repo.storage.dataPool.guardedServices = [
      "bonsai-storage-layout"
      "bonsai-model-prepare"
      "bonsai-llama"
    ];

    systemd.services.bonsai-storage-layout = {
      description = "Provision Bonsai model storage on the data pool";
      requires = [ "bonsai-model-archive.service" ];
      after = [ "bonsai-model-archive.service" ];
      before = [ "bonsai-model-prepare.service" ];
      unitConfig.RequiresMountsFor = [ vars.dataRoot ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/install -d -m 0750 -o bonsai -g bonsai ${lib.escapeShellArg "${vars.dataRoot}/bonsai"} ${lib.escapeShellArg modelDir}
        # The archive preserves numeric ownership while Bonsai is disabled;
        # restore access if its dynamically allocated UID changed on re-enable.
        ${pkgs.coreutils}/bin/chown -R bonsai:bonsai ${lib.escapeShellArg modelDir}
      '';
    };

    systemd.services.bonsai-model-prepare = {
      description = "Download and verify Ternary Bonsai 2 27B model artifacts";
      wants = [ "network-online.target" ];
      requires = [ "bonsai-storage-layout.service" ];
      after = [ "network-online.target" "bonsai-storage-layout.service" ];
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
        ReadWritePaths = [ cfg.stateDir modelDir ];
      };
    };
  };
}
