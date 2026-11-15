{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.search;
  ports = vars.networking.ports;
  loopback = vars.networking.loopbackIPv4;
  # Without OpenBLAS: it takes over CPU matrix products for inputs of 32+
  # tokens and re-converts the half-float embedding weights on every call.
  # Measured under these units' CPU quota, a 36-token query took 69s against
  # 1.3s without it and a full passage 78s against 9s, which stalled both long
  # questions and the library backfill.
  runtime = (import ../../lib/llama-cpp-runtime.nix { inherit pkgs; useVulkan = true; useBlas = false; }).runtime;
  # Q8_0 rather than f16: the same 2,560-dimensional vectors at half the
  # memory, which leaves room for the query embedder beside Bonsai on the one
  # card. A quant change alters every stored vector, so `semantic.rs` carries
  # the file hash in its VERSION and the next backfill re-embeds the library.
  embeddingModel = "${cfg.paths.models}/Qwen3-Embedding-4B-Q8_0.gguf";
  rerankerModel = "${cfg.paths.models}/Qwen3-Reranker-0.6B.F16.gguf";
  inferenceEnvironment = {
    SEARCH_EMBED_QUERY_URL = "http://${loopback}:${toString ports.searchEmbeddingQuery}";
    SEARCH_RERANK_URL = "http://${loopback}:${toString ports.searchReranker}";
    SEARCH_PASSAGE_CORE = "search-passages-v1";
  };
  prepare = pkgs.writeShellApplication {
    name = "search-prepare-models";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.util-linux ];
    text = builtins.readFile ../../scripts/admin/search-prepare-models.sh;
  };
  inferenceService = {
    wantedBy = [ "multi-user.target" ];
    requires = [ "search-model-prepare.service" ];
    after = [ "search-model-prepare.service" ];
    unitConfig.RequiresMountsFor = [ cfg.paths.models ];
    serviceConfig = {
      User = "search";
      Group = "search";
      Restart = "on-failure";
      RestartSec = "30s";
      TimeoutStartSec = "5min";
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      MemorySwapMax = "0";
      Nice = 10;
      CPUWeight = 30;
      IOWeight = 20;
      Environment = [ "MESA_SHADER_CACHE_DIR=/var/cache/search-inference" ];
      CacheDirectory = "search-inference";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };
in {
  options.repo.search.semantic = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Passage-level hybrid search using local Qwen3 4B embeddings and 0.6B reranking.";
    };
    indexingGpuLayers = lib.mkOption {
      type = lib.types.either lib.types.ints.positive (lib.types.enum [ "all" ]);
      default = "all";
      description = ''
        Layers of the Q8 indexing embedder held on the GPU while a backfill
        pass runs. Measured on the 23.9 GiB Arc Pro B60 with the Q8_0 file:
        every layer takes about 5.2 GiB beside Bonsai (about 10.5 GiB with two
        32K slots and the projector on the GPU), the query embedder (about
        4.3 GiB) and the trimmed reranker (about 2 GiB), which leaves only a
        small margin for vision and transcription. It embeds a passage in 0.6s
        against 9s with one layer. ggml-vulkan cannot spill a failed allocation
        to host RAM, so re-measure before adding another resident GPU model.
      '';
    };
    indexingGpuIdleStatus = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_status";
      description = ''
        The xe driver's render power state. A backfill pass reads it before
        each passage and waits while anything else is using the GPU, so chat,
        reranking and transcription keep their speed. A pass fails when the
        file cannot be read. Null disables yielding; pair that with a small
        indexingGpuLayers, since an unyielding full offload halves chat speed.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.semantic.enable) {
    assertions = [{
      assertion = lib.hasPrefix "${vars.dataRoot}/" cfg.paths.models;
      message = "Search model weights must stay on the data pool.";
    }];
    repo.storage.dataPool.guardedServices = [
      "search-model-prepare" "search-embedding-query" "search-reranker" "search-embed"
    ];
    hardware.graphics = {
      enable = true;
      extraPackages = [ pkgs.mesa pkgs.vulkan-loader ];
    };
    systemd.tmpfiles.rules = [
      "d ${vars.dataRoot}/search 0750 search search -"
      "d ${cfg.paths.models} 0750 search search -"
    ];
    systemd.services.search-model-prepare = {
      description = "Download and verify pinned Search embedding and reranking weights";
      requires = [ "data-pool-layout.service" ];
      after = [ "data-pool-layout.service" "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = [ cfg.paths.models ];
      environment.SEARCH_MODELS_DIR = cfg.paths.models;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "search";
        Group = "search";
        ExecStart = "${prepare}/bin/search-prepare-models";
        TimeoutStartSec = "2h";
        MemoryHigh = "128M";
        MemoryMax = "256M";
        Nice = 15;
        CPUWeight = 10;
        IOWeight = 10;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.paths.models ];
      };
    };
    # Pooled embeddings/reranking need a whole input in one physical batch.
    # Smaller micro-batches make llama.cpp clamp the accepted prompt length.
    systemd.services.search-embedding-query = lib.recursiveUpdate inferenceService {
      description = "Qwen3 4B Q8 query embeddings resident on the GPU";
      serviceConfig = {
        ExecStart = "${runtime}/bin/llama-server --model ${lib.escapeShellArg embeddingModel} --host ${loopback} --port ${toString ports.searchEmbeddingQuery} --embedding --pooling last --n-gpu-layers all --ctx-size 2048 --batch-size 2048 --ubatch-size 2048 --parallel 1 --threads 4 --flash-attn on";
        SupplementaryGroups = [ "render" "video" ];
        MemoryHigh = "10G";
        MemoryMax = "12G";
        CPUQuota = "400%";
      };
    };
    systemd.services.search-reranker = lib.recursiveUpdate inferenceService {
      description = "Qwen3 0.6B passage reranker resident on GPU";
      serviceConfig = {
        # A 4096-token batch sized the output buffer for the full 151k
        # vocabulary and held 4.1 GiB of the card. A search request reranks at
        # most three passages of about 200 tokens, so 1024/512 keeps the same
        # results in about 2 GiB.
        ExecStart = "${runtime}/bin/llama-server --model ${lib.escapeShellArg rerankerModel} --host ${loopback} --port ${toString ports.searchReranker} --reranking --n-gpu-layers all --ctx-size 4096 --batch-size 1024 --ubatch-size 512 --parallel 1 --threads 2 --flash-attn on";
        SupplementaryGroups = [ "render" "video" ];
        MemoryHigh = "2G";
        MemoryMax = "3G";
      };
    };
    systemd.services.search-ui.environment = inferenceEnvironment;
    systemd.services.search-ui.serviceConfig = {
      MemoryHigh = "1G";
      MemoryMax = "3G";
    };
    systemd.services.search-solr-core-bootstrap.environment.SEARCH_PASSAGE_CORE = "search-passages-v1";
    systemd.services.search-embed = {
      description = "Embed pending library passages on the GPU while it is otherwise idle";
      # A pass can run for hours, and activation would otherwise restart a
      # running pass and wait for the whole oneshot (TimeoutStartSec=infinity):
      # a guarded deploy then times out, and so does its rollback. Passes
      # commit to Solr before checkpointing, so the next timer run simply picks
      # up the new definition.
      restartIfChanged = false;
      requires = [ "search-model-prepare.service" "search-solr-core-bootstrap.service" "postgresql.service" ];
      after = [ "search-model-prepare.service" "search-solr-core-bootstrap.service" "postgresql.service" ];
      unitConfig.RequiresMountsFor = [ cfg.paths.models ];
      environment = config.systemd.services.search-index.environment // inferenceEnvironment // {
        SEARCH_LLAMA_SERVER = "${runtime}/bin/llama-server";
        SEARCH_EMBED_MODEL = embeddingModel;
        SEARCH_EMBED_INDEX_PORT = toString ports.searchEmbeddingIndex;
        SEARCH_EMBED_GPU_LAYERS = toString cfg.semantic.indexingGpuLayers;
      } // lib.optionalAttrs (cfg.semantic.indexingGpuIdleStatus != null) {
        SEARCH_EMBED_GPU_IDLE_STATUS = cfg.semantic.indexingGpuIdleStatus;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "search";
        Group = "search";
        SupplementaryGroups = [ "render" "video" ];
        ExecStart = "${cfg.package}/bin/search embed";
        TimeoutStartSec = "infinity";
        KillMode = "control-group";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        CacheDirectory = "search-inference";
        Environment = [ "MESA_SHADER_CACHE_DIR=/var/cache/search-inference" ];
        MemoryHigh = "10G";
        MemoryMax = "14G";
        MemorySwapMax = "0";
        Nice = 15;
        CPUWeight = 10;
        CPUQuota = "400%";
        IOWeight = 10;
      };
    };
    systemd.timers.search-embed = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; OnUnitInactiveSec = "30min"; Persistent = true; };
    };
  };
}
