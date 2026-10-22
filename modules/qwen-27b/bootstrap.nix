{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.qwen27b;
  # The MTP (NextN) draft head is only fetched when self-speculative decoding is
  # actually enabled, so a text/vision deployment does not download 1.3 GiB it
  # will never load.
  requiredArtifacts = lib.filter (artifact: !artifact.optional || cfg.mtp.enable) cfg.model.artifacts;
  artifactUrl = artifact:
    "https://huggingface.co/${cfg.model.repository}/resolve/${cfg.model.revision}/"
    + lib.optionalString (artifact.subdir != "") "${artifact.subdir}/"
    + "${artifact.file}?download=true";

  prepareModels = pkgs.writeShellApplication {
    name = "qwen-27b-model-prepare";
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
      '') requiredArtifacts}
    '';
  };
in
{
  options.repo.qwen27b = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether to run the local Qwen3.8-27B inference API. Disabled by
        default; enable after reviewing documentation/qwen-27b.md.
      '';
    };

    model = {
      repository = lib.mkOption {
        type = lib.types.str;
        default = "ukisai/Swift-1.5-Qwen3.8-27B-GGUF";
        readOnly = true;
        description = ''
          Authoritative Hugging Face GGUF repository. Swift 1.5 is UkisAI's
          reasoning-efficient post-training of Qwen/Qwen3.8-27B, quantised by
          llama.cpp. Measured 33% faster decode than the foundation Q4_K_M on
          this host. Reverting to the foundation weights means changing this,
          revision, mainFile, projectorFile and artifacts together.
        '';
      };

      revision = lib.mkOption {
        type = lib.types.str;
        default = "14bfe4b42be4a925d98816db830155f476c605e7";
        readOnly = true;
        description = "Pinned Hugging Face repository revision containing the verified artifacts.";
      };

      mainFile = lib.mkOption {
        type = lib.types.str;
        default = "Swift-1.5-Qwen3.8-27B-IQ4_XS.gguf";
        readOnly = true;
        description = ''
          Single-file IQ4_XS language-model GGUF. One step below Q4_K_M in
          quality but ~2 GiB smaller, which is what leaves room for the second
          parallel slot's KV cache and recurrent state.
        '';
      };

      projectorFile = lib.mkOption {
        type = lib.types.str;
        default = "mmproj-Swift-1.5-Qwen3.8-27B-F16.gguf";
        readOnly = true;
        description = ''
          Multimodal projector GGUF for vision input. Swift publishes its own
          projector rather than reusing the foundation model's, so this must be
          changed together with mainFile.
        '';
      };

      mtpFile = lib.mkOption {
        type = lib.types.str;
        default = "";
        readOnly = true;
        description = ''
          MTP (NextN) draft head GGUF. Empty because this repository publishes
          no MTP head, so mtp.enable has nothing to load and must stay false.
        '';
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
            optional = lib.mkOption {
              type = lib.types.bool;
              default = false;
              description = ''
                Skip this artifact unless the feature that needs it is enabled.
                Used for the MTP draft head, which is only loaded when
                repo.qwen27b.mtp.enable is true.
              '';
            };
          };
        });
        default = [
          {
            file = "Swift-1.5-Qwen3.8-27B-IQ4_XS.gguf";
            sha256 = "e3b59faa312a6202d7ac0a2400123956104bc720e77f6ff21c754aec5c3740df";
            sizeBytes = 15475951296;
          }
          {
            file = "mmproj-Swift-1.5-Qwen3.8-27B-F16.gguf";
            sha256 = "10a24dc46eb801ad794886ef27ea1e43634d35388dfaf2e2374b7a8b67faf526";
            sizeBytes = 927606912;
          }
        ];
        description = "Hash-verified GGUF artifacts that must be present before inference starts.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.qwen-27b-model-prepare = {
      description = "Download and verify Qwen3.8-27B model artifacts";
      wants = [ "network-online.target" "qwen-27b-storage-layout-v1.service" ];
      after = [ "network-online.target" "qwen-27b-storage-layout-v1.service" ];
      unitConfig = {
        RequiresMountsFor = [ vars.dataRoot ];
        StartLimitIntervalSec = "1h";
        StartLimitBurst = 4;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "qwen-27b";
        Group = "qwen-27b";
        ExecStart = "${prepareModels}/bin/qwen-27b-model-prepare";
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
