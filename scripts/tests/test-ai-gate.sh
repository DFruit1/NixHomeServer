#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix cargo

host="$(test_default_host)"
# `ai-gate` is owned by the removable `bonsai` app. Only compile it when bonsai
# is actually enabled; otherwise this test would build a disabled crate on every
# lean/full validation. Evaluation of the gate wiring below already short
# circuits with `skipped = true` in that case.
bonsai_enabled="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --raw --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    c = f.nixosConfigurations.${builtins.getEnv "NIXHOMESERVER_TEST_HOST"}.config;
  in
    if ((c.nixhomeserver.modules.bonsai or false) && c.repo.bonsai.enable) then "1" else "0"
' 2>/dev/null || echo 0)"

if [[ "$bonsai_enabled" == "1" ]]; then
  # Rust unit tests: queue boundary, settings validation, query encoding. Reuse
  # a persistent, incremental target dir so repeated runs do not recompile the
  # crate graph from scratch (the ops shell does not set CARGO_BUILD_TARGET_DIR).
  target_dir="${XDG_CACHE_HOME:-$HOME/.cache}/nixhomeserver-cargo/ai-gate-check"
  mkdir -p "$target_dir"
  cargo_log="$(mktemp)"
  trap 'rm -f "$cargo_log"' EXIT
  if ! CARGO_TARGET_DIR="$target_dir" CARGO_INCREMENTAL=1 nix develop .#ops --command cargo test \
    --manifest-path custom_apps/Cargo.toml -p ai-gate --locked >"$cargo_log" 2>&1; then
    cat "$cargo_log" >&2
    exit 1
  fi
  tail -n 5 "$cargo_log"
fi

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
