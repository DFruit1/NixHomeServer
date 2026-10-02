#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

# The interactive UI is Bonsai-only and Qwen is a separate background server.
require_fixed modules/bonsai/services.nix '--path ${cfg.runtime.webui}' \
  "Bonsai server must serve the pinned web UI."
require_fixed modules/qwen-27b/services.nix '--path ${cfg.runtime.webui}' \
  "Qwen server must serve the pinned chat UI."

host="$(test_default_host)"
NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    base = f.nixosConfigurations.${builtins.getEnv "NIXHOMESERVER_TEST_HOST"};
    c = base.config;
    enabled = (c.nixhomeserver.modules.bonsai or false)
      && (c.nixhomeserver.modules.qwen-27b or false)
      && c.repo.bonsai.enable && c.repo.qwen27b.enable;
    withoutBonsai = (base.extendModules { modules = [
      ({ lib, ... }: { repo.bonsai.enable = lib.mkForce false; })
    ]; }).config;
    qwenUpstream = "http://${c.repo.qwen27b.listenAddress}:${toString c.repo.qwen27b.port}";
  in if !enabled then { skipped = true; } else {
    skipped = false;
    bonsaiWebui = c.repo.bonsai.runtime ? webui;
    qwenWebui = c.repo.qwen27b.runtime ? webui;
    bonsaiBoot = builtins.elem "multi-user.target" c.systemd.services.bonsai-llama.wantedBy;
    bonsaiRequiresQwen = builtins.elem "qwen-27b-model-prepare.service" c.systemd.services.bonsai-llama.requires;
    qwenCommand = c.systemd.services.qwen-27b-llama.serviceConfig.ExecStart;
    qwenBoot = builtins.elem "multi-user.target" c.systemd.services.qwen-27b-llama.wantedBy;
    qwenConflicts = c.systemd.services.qwen-27b-llama.conflicts;
    qwenOnSuccess = c.systemd.services.qwen-27b-llama.unitConfig.OnSuccess;
    restoreExec = c.systemd.services.bonsai-llama-restore.serviceConfig.ExecStart;
    restoreWantedBy = c.systemd.services.bonsai-llama-restore.wantedBy;
    qwenPort = c.repo.qwen27b.port;
    bonsaiPort = c.repo.bonsai.port;
    qwenListen = c.repo.qwen27b.listenAddress;
    uiUpstream = c.repo.authGateway.protectedApps.bonsai.upstream;
    qwenExposed = builtins.any
      (app: (app.upstream or "") == qwenUpstream)
      (builtins.attrValues c.repo.authGateway.protectedApps);
    withoutBonsaiQwenBoot = builtins.elem "multi-user.target" withoutBonsai.systemd.services.qwen-27b-llama.wantedBy;
    withoutBonsaiQwenConflicts = withoutBonsai.systemd.services.qwen-27b-llama.conflicts or [ ];
    withoutBonsaiHasRestore = builtins.hasAttr "bonsai-llama-restore" withoutBonsai.systemd.services;
  }
' | jq -e '.skipped or (
  .bonsaiWebui
  and .qwenWebui
  and .bonsaiBoot
  and (.bonsaiRequiresQwen | not)
  and (.qwenCommand | contains("qwen-27b-llama-server"))
  and (.qwenBoot | not)
  and (.qwenConflicts | index("bonsai-llama.service") != null)
  and (.qwenOnSuccess | index("bonsai-llama-restore.service") != null)
  and (.restoreExec | contains("start bonsai-llama.service bonsai-gate.service"))
  and (.restoreWantedBy == [])
  and (.qwenPort != .bonsaiPort)
  and .qwenListen == "127.0.0.1"
  and (.uiUpstream == ("http://127.0.0.1:" + (.bonsaiPort | tostring)))
  and .qwenExposed
  and .withoutBonsaiQwenBoot
  and (.withoutBonsaiQwenConflicts == [])
  and (.withoutBonsaiHasRestore | not)
)' >/dev/null
echo "Bonsai and Qwen UIs, on-demand Qwen background model, and disable isolation passed."
