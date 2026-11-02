{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.transcribe;
  artifacts = [
    { name = "parakeet.bin"; url = "https://huggingface.co/ggml-org/parakeet-GGUF/resolve/35156454d1a39de06863303dd209fd2bed6ee079/ggml-parakeet-tdt-0.6b-v3-q8_0.bin"; hash = "4d64e9e96c2792186d072fde0034df0ad670cf680a2f53069052ead827fd600e"; }
    { name = "whisper.bin"; url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin"; hash = "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"; }
    { name = "segmentation.onnx"; url = "https://huggingface.co/csukuangfj/sherpa-onnx-pyannote-segmentation-3-0/resolve/9403a6902bb58e3d5ae8c7e77c3422de279db2e0/model.onnx"; hash = "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"; }
    { name = "embedding.onnx"; url = "https://huggingface.co/csukuangfj/speaker-embedding-models/resolve/0743f301363dec56491a490f6d6cbc9d67f9a3bf/wespeaker_en_voxceleb_resnet152_LM.onnx"; hash = "3e1c2c7a02097bdddc27c1cf7382237399abdc3b5b682e59455830673c6686e7"; }
  ];
in {
  config = lib.mkIf cfg.enable {
    systemd.services.transcribe-model-prepare = {
      description = "Verify pinned speech and speaker models on the data pool";
      requires = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = [ vars.dataRoot ];
      path = [ pkgs.coreutils pkgs.curl ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; TimeoutStartSec = "1h"; UMask = "0077"; Nice = 15; CPUWeight = 10; IOWeight = 10; MemoryHigh = "128M"; MemoryMax = "256M"; ProtectSystem = "strict"; ReadWritePaths = [ cfg.modelsDir ]; NoNewPrivileges = true; PrivateTmp = true; };
      script = ''
        set -euo pipefail
        cd ${lib.escapeShellArg cfg.modelsDir}
        ${lib.concatMapStringsSep "\n" (artifact: ''
          if ! printf '%s  %s\n' ${lib.escapeShellArg artifact.hash} ${lib.escapeShellArg artifact.name} | sha256sum --check --status; then
            part=$(mktemp .download.XXXXXX)
            trap 'rm -f -- "$part"' EXIT
            curl --fail --location --retry 3 --connect-timeout 15 --max-time 1800 ${lib.escapeShellArg artifact.url} --output "$part"
            printf '%s  %s\n' ${lib.escapeShellArg artifact.hash} "$part" | sha256sum --check --status
            chmod 0640 "$part"
            mv -- "$part" ${lib.escapeShellArg artifact.name}
            trap - EXIT
          fi
        '') artifacts}
      '';
    };
  };
}
