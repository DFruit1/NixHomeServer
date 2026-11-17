{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.search;
  slots = cfg.semantic.rerankSlots;
  ports = vars.networking.ports;
  loopback = vars.networking.loopbackIPv4;
  # Without OpenBLAS: it takes over CPU matrix products for inputs of 32+
  # tokens and re-converts the half-float embedding weights on every call.
  # Measured under these units' CPU quota, a 36-token query took 69s against
  # 1.3s without it and a full passage 78s against 9s, which stalled both long
  # questions and the library backfill.
  runtime = (import ../../lib/llama-cpp-runtime.nix { inherit pkgs; useVulkan = true; useBlas = false; }).runtime;
  # Q8_0 rather than f16: the same 2,560-dimensional vectors at half the
  # memory. One resident copy serves both queries and the library backfill. A
  # quant change alters every stored vector, so `semantic.rs` carries the file
  # hash in its VERSION and the next backfill re-embeds the library.
  embeddingModel = "${cfg.paths.models}/Qwen3-Embedding-4B-Q8_0.gguf";
  # 4B Q8_0 reranker: better relevance judgements than the 0.6B, paid for
  # with the memory the backfill's second embedder copy used to hold.
  rerankerModel = "${cfg.paths.models}/Qwen3-Reranker-4B.Q8_0.gguf";
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
      description = "Passage-level hybrid search using local Qwen3 4B embeddings and 4B reranking.";
    };
    indexingGpuIdleStatus = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "/sys/class/drm/card0/device/tile0/gt0/gtidle/idle_status";
      description = ''
        The xe driver's render power state. A backfill pass reads it before
        each passage and waits while anything else is using the GPU, so chat,
        reranking and transcription keep their speed. A pass fails when the
        file cannot be read. Null disables yielding, which roughly halves
        chat speed while a pass runs.
      '';
    };
    rerankSlots = lib.mkOption {
      type = lib.types.ints.between 1 2;
      default = 1;
      description = ''
        Parallel rerank requests the resident server serves. More than one
        slot only helps where the pinned llama.cpp supports concurrent rerank
        requests, and the search client keeps at most this many chunk requests
        in flight. Each extra slot doubles the reserved context (--ctx-size
        becomes 2048 * slots), so measure VRAM on the card before raising it.
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
      # Read-only advisory lease shared by bulk GPU jobs (Search's backfill
      # and the Media Manager photo-tag reviewer). flock(2) works on a
      # read-only descriptor, so both service users can open it without a
      # shared group or a writable /run directory.
      "f /run/ai-gpu-bulk.lease 0644 root root -"
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
      # Also the backfill's embedder. Measured with the Q8_0 file: 5.75 GiB,
      # beside Bonsai (10.64 GiB at the 76K Q8 pool) and the 4B reranker
      # (4.60 GiB), which leaves 2.9 GiB of the 23.9 GiB Arc Pro B60.
      # ggml-vulkan cannot spill a failed allocation to host RAM, so re-measure
      # before adding another resident GPU model.
      description = "Qwen3 4B Q8 query and backfill embeddings resident on the GPU";
      serviceConfig = {
        ExecStart = "${runtime}/bin/llama-server --model ${lib.escapeShellArg embeddingModel} --host ${loopback} --port ${toString ports.searchEmbeddingQuery} --embedding --pooling last --n-gpu-layers all --ctx-size 2048 --batch-size 2048 --ubatch-size 2048 --parallel 1 --threads 4 --flash-attn on";
        SupplementaryGroups = [ "render" "video" ];
        MemoryHigh = "10G";
        MemoryMax = "12G";
        CPUQuota = "400%";
      };
    };
    systemd.services.search-reranker = lib.recursiveUpdate inferenceService {
      description = "Qwen3 4B Q8 passage reranker resident on GPU";
      serviceConfig = {
        # A 4096-token batch sized the output buffer for the full 151k
        # vocabulary and held 4.1 GiB of the card on the 0.6B. A search request
        # reranks three passages of roughly 200-340 tokens each, and every
        # sequence must fit one physical batch: a 512-token micro-batch needs
        # two passes, so this uses 1024. --ctx-size and --parallel follow
        # rerankSlots (2048 tokens per slot). The larger micro-batch and any
        # extra slot cost VRAM, so re-measure on the card (2.9 GiB free with a
        # backfill pass running) before raising either.
        ExecStart = "${runtime}/bin/llama-server --model ${lib.escapeShellArg rerankerModel} --host ${loopback} --port ${toString ports.searchReranker} --reranking --n-gpu-layers all --ctx-size ${toString (2048 * slots)} --batch-size 1024 --ubatch-size 1024 --parallel ${toString slots} --threads 2 --flash-attn on";
        SupplementaryGroups = [ "render" "video" ];
        MemoryHigh = "6G";
        MemoryMax = "8G";
      };
    };
    systemd.services.search-ui.environment = inferenceEnvironment // {
      SEARCH_RERANK_SLOTS = toString slots;
    };
    systemd.services.search-ui.serviceConfig = {
      MemoryHigh = "1G";
      MemoryMax = "3G";
    };
    systemd.services.search-solr-core-bootstrap.environment.SEARCH_PASSAGE_CORE = "search-passages-v1";
    systemd.services.search-embed = {
      description = "Embed pending library passages through the resident embedder while the GPU is otherwise idle";
      # A pass can run for hours, and activation would otherwise restart a
      # running pass and wait for the whole oneshot (TimeoutStartSec=infinity):
      # a guarded deploy then times out, and so does its rollback. Passes
      # commit to Solr before checkpointing, so the next timer run simply picks
      # up the new definition.
      restartIfChanged = false;
      # Wants rather than Requires: an embedder restart must not kill a running
      # pass. Its next request fails instead, and the timer retries from the
      # last checkpoint.
      requires = [ "search-solr-core-bootstrap.service" "postgresql.service" ];
      wants = [ "search-embedding-query.service" ];
      after = [ "search-embedding-query.service" "search-solr-core-bootstrap.service" "postgresql.service" ];
      environment = config.systemd.services.search-index.environment // inferenceEnvironment // lib.optionalAttrs (cfg.semantic.indexingGpuIdleStatus != null) {
        SEARCH_EMBED_GPU_IDLE_STATUS = cfg.semantic.indexingGpuIdleStatus;
      };
      serviceConfig = {
        Type = "oneshot";
        User = "search";
        Group = "search";
        ExecStart = "${cfg.package}/bin/search embed";
        TimeoutStartSec = "infinity";
        KillMode = "control-group";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        # Only the pass itself now: documents in flight, no model weights.
        MemoryHigh = "1G";
        MemoryMax = "3G";
        MemorySwapMax = "0";
        Nice = 15;
        CPUWeight = 10;
        IOWeight = 10;
      };
    };
    systemd.timers.search-embed = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "15min"; OnUnitInactiveSec = "30min"; Persistent = true; };
    };
    # Probes the resident inference servers so a silent misconfiguration (for
    # example a reranking model file that lacks llama.cpp's required conversion
    # contract) surfaces as an alert rather than a slow search result.
    systemd.services.search-inference-health = {
      description = "Probe the resident Search embedding and reranking servers";
      after = [ "search-embedding-query.service" "search-reranker.service" ];
      unitConfig = {
        OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
        OnFailureJobMode = "replace-irreversibly";
        # A probe that starts while activation is restarting an inference
        # server would fail on a model that is still loading. Retry a few times
        # before the unit is failed and the alert is delivered.
        StartLimitBurst = 3;
        StartLimitIntervalSec = 300;
      };
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = 20;
        User = "search";
        Group = "search";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        RestrictNamespaces = true;
        RestrictSUIDSGID = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        SystemCallArchitectures = "native";
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
        MemoryHigh = "64M";
        MemoryMax = "128M";
        MemorySwapMax = "0";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
      script = ''
        set -euo pipefail
        curl=${pkgs.curl}/bin/curl
        jq=${pkgs.jq}/bin/jq
        embed_url="http://${loopback}:${toString ports.searchEmbeddingQuery}"
        rerank_url="http://${loopback}:${toString ports.searchReranker}"
        status=0

        if ! "$curl" -fsS --max-time 20 "$embed_url/health" >/dev/null; then
          echo "search-inference-health: embedder /health failed at $embed_url" >&2
          status=1
        fi
        if ! "$curl" -fsS --max-time 20 "$rerank_url/health" >/dev/null; then
          echo "search-inference-health: reranker /health failed at $rerank_url" >&2
          status=1
        fi
        if ! rerank_resp="$("$curl" -fsS --max-time 60 \
            -H 'Content-Type: application/json' \
            --data '{"query":"canary","documents":["canary passage"],"top_n":1}' \
            "$rerank_url/v1/rerank")"; then
          echo "search-inference-health: reranker /v1/rerank at $rerank_url failed" >&2
          status=1
        elif ! printf '%s' "$rerank_resp" | "$jq" -e '
            [ .results[]?.relevance_score // empty
              | select(type == "number")
              | select(. == . and . != infinite and . != -infinite) ]
            | length > 0
          ' >/dev/null; then
          echo "search-inference-health: reranker /v1/rerank returned no finite relevance_score" >&2
          status=1
        fi
        exit "$status"
      '';
    };
    systemd.timers.search-inference-health = {
      description = "Probe the resident Search embedding and reranking servers";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10min";
        OnUnitInactiveSec = "15min";
        Persistent = true;
        Unit = "search-inference-health.service";
      };
    };
  };
}
