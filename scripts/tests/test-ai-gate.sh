#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix cargo

# Rust unit tests: queue boundary, settings validation, query encoding.
cargo test --manifest-path custom_apps/Cargo.toml -p ai-gate --locked 2>&1 | tail -n 5

host="$(test_default_host)"
NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    base = f.nixosConfigurations.${builtins.getEnv "NIXHOMESERVER_TEST_HOST"};
    c = base.config;
    bonsaiOn = (c.nixhomeserver.modules.bonsai or false) && c.repo.bonsai.enable;
    paperlessOn = (c.nixhomeserver.modules.paperless or false) && c.repo.paperless.v3.enable or false;
  in if !bonsaiOn then { skipped = true; } else {
    skipped = false;
    gateWanted = builtins.elem "multi-user.target" c.systemd.services.bonsai-gate.wantedBy;
    gateRequires = c.systemd.services.bonsai-gate.requires;
    gateAfter = c.systemd.services.bonsai-gate.after;
    gateExec = c.systemd.services.bonsai-gate.serviceConfig.ExecStart;
    gateEnv = c.systemd.services.bonsai-gate.environment;
    gateMemoryMax = c.systemd.services.bonsai-gate.serviceConfig.MemoryMax;
    gateMemoryHigh = c.systemd.services.bonsai-gate.serviceConfig.MemoryHigh;
    gateCpuQuota = c.systemd.services.bonsai-gate.serviceConfig.CPUQuota;
    gateUser = c.systemd.services.bonsai-gate.serviceConfig.User;
    gateNoNewPrivs = c.systemd.services.bonsai-gate.serviceConfig.NoNewPrivileges;
    gatePrivateTmp = c.systemd.services.bonsai-gate.serviceConfig.PrivateTmp;
    gateBaseUrl = c.repo.bonsai.gate.gateBaseUrl;
    gatePort = c.repo.bonsai.gate.port;
    llamaPort = c.repo.bonsai.port;
    llamaWeight = c.systemd.services.bonsai-llama.serviceConfig.CPUWeight;
    llamaNice = c.systemd.services.bonsai-llama.serviceConfig.Nice;
    llamaOom = c.systemd.services.bonsai-llama.serviceConfig.OOMScoreAdjust;
    paperlessEndpoint = if paperlessOn then c.services.paperless.settings.PAPERLESS_AI_LLM_ENDPOINT else "n/a";
    paperlessModel = if paperlessOn then c.services.paperless.settings.PAPERLESS_AI_LLM_MODEL else "n/a";
    paperlessEmbeddings = if paperlessOn then (c.services.paperless.settings ? PAPERLESS_AI_LLM_EMBEDDING_BACKEND) else false;
    paperlessOnAttr = paperlessOn;
    maxQueued = c.repo.bonsai.gate.maxQueued;
    queueTimeout = c.repo.bonsai.gate.queueTimeoutSecs;
    upstreamTimeout = c.repo.bonsai.gate.upstreamTimeoutSecs;
    disabledGateOff = ((base.extendModules { modules = [
      ({ lib, ... }: { repo.bonsai.enable = lib.mkForce false; })
    ]; }).config.systemd.services.bonsai-gate.wantedBy or []) == [];
  }
' | jq -e '.skipped or (
  .gateWanted
  and (.gateRequires | index("bonsai-llama.service") != null)
  and (.gateAfter | index("bonsai-llama.service") != null)
  and (.gateExec | contains("/bin/ai-gate"))
  and .gateEnv.AI_GATE_MAX_INFLIGHT == "1"
  and .gateEnv.AI_GATE_UPSTREAM_TIMEOUT_SECS == "600"
  and .gateMemoryMax == "512M"
  and .gateMemoryHigh == "256M"
  and .gateCpuQuota == "50%"
  and .gateUser == "bonsai"
  and .gateNoNewPrivs == true
  and .gatePrivateTmp == true
  and .gateBaseUrl == "http://127.0.0.1:8094/v1"
  and .gatePort == 8094
  and .gatePort != .llamaPort
  and .llamaWeight == 20
  and .llamaNice == 10
  and .llamaOom == 500
  and .maxQueued == 2
  and .maxQueued <= 4
  and .queueTimeout == 60
  and .upstreamTimeout == 600
  and (.paperlessOnAttr | not or (.paperlessEndpoint == "http://127.0.0.1:8094/v1"))
  and (.paperlessOnAttr | not or (.paperlessModel == "bonsai-ternary-27b"))
  and (.paperlessOnAttr | not or (.paperlessEmbeddings | not))
  and .disabledGateOff
)' >/dev/null
echo "AI gate serialization, resource caps, and Paperless Suggest-only wiring passed."
