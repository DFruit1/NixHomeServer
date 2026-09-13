#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

# The interactive UI is Bonsai-only and Qwen is a separate background server.
require_fixed modules/bonsai/services.nix '--path ${cfg.runtime.webui}' \
  "Bonsai server must serve the pinned web UI."
require_fixed modules/qwen-flash-next/services.nix '--no-webui' \
  "Qwen server must not serve a web UI."
forbid_match modules/qwen-flash-next/services.nix '--path' \
  "Qwen background server must not serve the UI static path."

host="$(test_default_host)"
NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    base = f.nixosConfigurations.${builtins.getEnv "NIXHOMESERVER_TEST_HOST"};
    c = base.config;
    enabled = (c.nixhomeserver.modules.bonsai or false)
      && (c.nixhomeserver.modules.qwen-flash-next or false)
      && c.repo.bonsai.enable && c.repo.qwenFlashNext.enable;
    withoutBonsai = (base.extendModules { modules = [
      ({ lib, ... }: { repo.bonsai.enable = lib.mkForce false; })
    ]; }).config;
    qwenUpstream = "http://${c.repo.qwenFlashNext.listenAddress}:${toString c.repo.qwenFlashNext.port}";
  in if !enabled then { skipped = true; } else {
    skipped = false;
    bonsaiWebui = c.repo.bonsai.runtime ? webui;
    qwenWebui = c.repo.qwenFlashNext.runtime ? webui;
    bonsaiBoot = builtins.elem "multi-user.target" c.systemd.services.bonsai-llama.wantedBy;
    bonsaiRequiresQwen = builtins.elem "qwen-flash-next-model-prepare.service" c.systemd.services.bonsai-llama.requires;
    qwenCommand = c.systemd.services.qwen-flash-next-llama.serviceConfig.ExecStart;
    qwenBoot = builtins.elem "multi-user.target" c.systemd.services.qwen-flash-next-llama.wantedBy;
    qwenConflicts = c.systemd.services.qwen-flash-next-llama.conflicts;
    qwenOnSuccess = c.systemd.services.qwen-flash-next-llama.unitConfig.OnSuccess;
    restoreExec = c.systemd.services.bonsai-llama-restore.serviceConfig.ExecStart;
    restoreWantedBy = c.systemd.services.bonsai-llama-restore.wantedBy;
    qwenPort = c.repo.qwenFlashNext.port;
    bonsaiPort = c.repo.bonsai.port;
    qwenListen = c.repo.qwenFlashNext.listenAddress;
    uiUpstream = c.repo.authGateway.protectedApps.bonsai.upstream;
    qwenExposed = builtins.any
      (app: (app.upstream or "") == qwenUpstream)
      (builtins.attrValues c.repo.authGateway.protectedApps);
    withoutBonsaiQwenBoot = builtins.elem "multi-user.target" withoutBonsai.systemd.services.qwen-flash-next-llama.wantedBy;
    withoutBonsaiQwenConflicts = withoutBonsai.systemd.services.qwen-flash-next-llama.conflicts or [ ];
    withoutBonsaiHasRestore = builtins.hasAttr "bonsai-llama-restore" withoutBonsai.systemd.services;
  }
' | jq -e '.skipped or (
  .bonsaiWebui
  and (.qwenWebui | not)
  and .bonsaiBoot
  and (.bonsaiRequiresQwen | not)
  and (.qwenCommand | contains("qwen-flash-next-llama-server"))
  and (.qwenBoot | not)
  and (.qwenConflicts | index("bonsai-llama.service") != null)
  and (.qwenOnSuccess | index("bonsai-llama-restore.service") != null)
  and (.restoreExec | contains("start bonsai-llama.service bonsai-gate.service"))
  and (.restoreWantedBy == [])
  and (.qwenPort != .bonsaiPort)
  and .qwenListen == "127.0.0.1"
  and (.uiUpstream == ("http://127.0.0.1:" + (.bonsaiPort | tostring)))
  and (.qwenExposed | not)
  and .withoutBonsaiQwenBoot
  and (.withoutBonsaiQwenConflicts == [])
  and (.withoutBonsaiHasRestore | not)
)' >/dev/null
echo "Bonsai-only UI, on-demand Qwen background model, and disable isolation passed."
