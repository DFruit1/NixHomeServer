{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.search;
  ports = vars.networking.ports;
  loopback = vars.networking.loopbackIPv4;
  runtime = (import ../../lib/llama-cpp-runtime.nix { inherit pkgs; useVulkan = true; }).runtime;
  embeddingModel = "${cfg.paths.models}/Qwen3-Embedding-4B-f16.gguf";
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
      type = lib.types.ints.positive;
      default = 1;
      description = ''
        Limited indexing GPU offload. Chat stays available; the F16 4B model
        otherwise lives in RAM. Increase only after measuring simultaneous
        chat, reranker and indexing VRAM usage. No chat allocation is changed.
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
    systemd.services.search-embedding-query = lib.recursiveUpdate inferenceService {
      description = "Qwen3 4B query embeddings on CPU and system RAM";
      serviceConfig = {
        ExecStart = "${runtime}/bin/llama-server --model ${lib.escapeShellArg embeddingModel} --host ${loopback} --port ${toString ports.searchEmbeddingQuery} --embedding --pooling last --n-gpu-layers 0 --device none --ctx-size 2048 --batch-size 2048 --ubatch-size 512 --parallel 1 --threads 4";
        MemoryHigh = "10G";
        MemoryMax = "12G";
        CPUQuota = "400%";
      };
    };
    systemd.services.search-reranker = lib.recursiveUpdate inferenceService {
      description = "Qwen3 0.6B passage reranker resident on GPU";
      serviceConfig = {
        ExecStart = "${runtime}/bin/llama-server --model ${lib.escapeShellArg rerankerModel} --host ${loopback} --port ${toString ports.searchReranker} --reranking --n-gpu-layers all --ctx-size 4096 --batch-size 2048 --ubatch-size 256 --parallel 1 --threads 2 --flash-attn on";
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
      description = "Embed pending library passages with limited GPU offload";
      requires = [ "search-model-prepare.service" "search-solr-core-bootstrap.service" "postgresql.service" ];
      after = [ "search-model-prepare.service" "search-solr-core-bootstrap.service" "postgresql.service" ];
      unitConfig.RequiresMountsFor = [ cfg.paths.models ];
      environment = config.systemd.services.search-index.environment // inferenceEnvironment // {
        SEARCH_LLAMA_SERVER = "${runtime}/bin/llama-server";
        SEARCH_EMBED_MODEL = embeddingModel;
        SEARCH_EMBED_INDEX_PORT = toString ports.searchEmbeddingIndex;
        SEARCH_EMBED_GPU_LAYERS = toString cfg.semantic.indexingGpuLayers;
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
