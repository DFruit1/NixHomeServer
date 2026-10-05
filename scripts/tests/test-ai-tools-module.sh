#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools jq nix
host="$(test_default_host)"
if [[ "$(flake_eval_json "in builtins.elem \"ai-tools\" (builtins.getAttr \"$host\" f.lib.nixhomeserverSettings).enabledApps")" != true ]]; then
  echo 'AI Tools is disabled; skipping its enabled-module contract.'
  exit 0
fi

# The published host name is the regression this test exists for: rmcp rejects
# any Host it was not configured with, Caddy forwards the client's Host
# unchanged, and the only symptom is a 403 on every request through the gateway.
# Asserting the unit exports it is far cheaper than finding that on the
# deployed endpoint.
value="$(flake_eval_json "
  cfg = (builtins.getAttr \"$host\" f.nixosConfigurations).config;
  vars = builtins.getAttr \"$host\" f.lib.nixhomeserverSettings;
  svc = cfg.systemd.services.ai-tools;
  shared = cfg.systemd.services.ai-tools-shared-access;
  app = cfg.repo.aiTools;
  gateway = cfg.repo.authGateway.protectedApps.aiTools;
  guarded = cfg.repo.storage.dataPool.guardedServices;
  workspaceDirs = lib.filter
    (name: name == app.workspaceDirName)
    cfg.repo.storage.sharedRoots.contentSubdirs;
  workspaceProvisions = lib.filter
    (dir: dir.path == app.workspaceRoot)
    cfg.repo.storage.dataPool.directories;
in {
  publicHost = \"tools.\${vars.domain}\";
  envPublicHost = svc.environment.AI_TOOLS_PUBLIC_HOST;
  envListen = svc.environment.AI_TOOLS_LISTEN;
  envSharedRoot = svc.environment.AI_TOOLS_SHARED_ROOT;
  envWorkspace = svc.environment.AI_TOOLS_WORKSPACE_ROOT;
  envSearxng = svc.environment.AI_TOOLS_SEARXNG_URL;
  gatewayHost = gateway.host;
  gatewayUpstream = gateway.upstream;
  ipDeny = svc.serviceConfig.IPAddressDeny;
  ipAllow = svc.serviceConfig.IPAddressAllow;
  onFailure = svc.unitConfig.OnFailure;
  alertTarget = cfg.repo.monitoring.failureAlerts.targetUnit;
  requiresMounts = svc.serviceConfig.RequiresMountsFor;
  readOnlyPaths = svc.serviceConfig.ReadOnlyPaths;
  readWritePaths = svc.serviceConfig.ReadWritePaths;
  memoryHigh = svc.serviceConfig.MemoryHigh;
  memoryMax = svc.serviceConfig.MemoryMax;
  user = svc.serviceConfig.User;
  aclScript = shared.script;
  aclBefore = shared.before;
  guardedService = builtins.elem \"ai-tools\" guarded;
  guardedAcl = builtins.elem \"ai-tools-shared-access\" guarded;
  listen = app.listenAddress;
  port = app.port;
  workspaceRoot = app.workspaceRoot;
  workspaceDirs = workspaceDirs;
  workspaceProvisions = workspaceProvisions;
  # The confinement this card exists for: reads keep the whole shared root,
  # writes are confined to the workspace, and the workspace is a child of it.
  workspaceUnderSharedRoot =
    app.workspaceRoot != app.sharedRoot
    && lib.hasPrefix \"\${app.sharedRoot}/\" app.workspaceRoot;
  # Nothing but the workspace may be writable, and it must not sit outside the
  # read-only root where the mount would not nest.
  writePathsExactlyWorkspace =
    svc.serviceConfig.ReadWritePaths == [ app.workspaceRoot ];
  readOnlyIsWholeSharedRoot =
    svc.serviceConfig.ReadOnlyPaths == [ app.sharedRoot ];
  # The workspace is deliberately unbacked-up; a snapshot root reaching it is
  # the regression to catch.
  snapshotRoots = cfg.repo.backups.snapshotRoots;
  snapshotRootsCoverWorkspace = lib.any
    (root: app.workspaceRoot == root || lib.hasPrefix \"\${root}/\" app.workspaceRoot)
    cfg.repo.backups.snapshotRoots;
  gatewayMode = cfg.repo.authGateway.mode;
  disableEvaluation = (f.nixosConfigurations.\"$host\".extendModules { modules = [
    ({ lib, ... }: { repo.aiTools.enable = lib.mkForce false; })
  ]; }).config.systemd.services.ai-tools.wantedBy or [];
}")"

jq -e '
  .alertTarget as $alert
  | .envSharedRoot as $shared
  | .envWorkspace as $workspace
  | (
  .envPublicHost == .publicHost
  and .gatewayHost == .publicHost
  and (.envListen | startswith("127.0.0.1:"))
  and (.envSearxng | startswith("http://127.0.0.1:"))
  and (.gatewayUpstream | startswith("http://127.0.0.1:"))
  and (.envSharedRoot | startswith("/"))
  and (.envWorkspace | startswith($shared + "/"))
  and .ipDeny == "any"
  and .ipAllow == "localhost"
  and (.onFailure | index($alert) != null)
  and (.requiresMounts | index($shared) != null)
  and (.requiresMounts | index($workspace) != null)
  and (.readOnlyPaths | index($shared) != null)
  and (.readWritePaths | index($workspace) != null)
  and .readOnlyIsWholeSharedRoot
  and .writePathsExactlyWorkspace
  and .workspaceUnderSharedRoot
  and (.workspaceRoot == $workspace)
  and (.workspaceDirs | index("ai-workspace") != null)
  and (.workspaceProvisions | length == 1)
  and (.workspaceProvisions[0].mode == "0770")
  and (.workspaceProvisions[0].path == $workspace)
  and (.memoryHigh != null)
  and (.memoryMax != null)
  and .user == "ai-tools"
  and (.aclScript | contains("g:ai-tools:r-x"))
  and (.aclScript | contains("g:ai-tools:rwx"))
  and (.aclScript | contains("$workspace"))
  and (.aclBefore | index("ai-tools.service") != null)
  and .guardedService
  and .guardedAcl
  and .listen == "127.0.0.1"
  and .port == 8097
  and .gatewayMode == "gateway"
  and (.disableEvaluation | length == 0)
  )
' <<<"$value" >/dev/null ||
  {
    echo "❌ AI Tools public host, egress confinement or shared-root access regressed." >&2
    jq . <<<"$value" >&2
    exit 1
  }

# The inference unit must gain nothing from the workspace: the grant belongs to
# ai-tools alone, so the account llama-server runs as cannot write it either.
inference="$(flake_eval_json "
  cfg = (builtins.getAttr \"$host\" f.nixosConfigurations).config;
  app = cfg.repo.aiTools;
  qwen = cfg.systemd.services.qwen-27b-llama;
in {
  workspace = app.workspaceRoot;
  qwenUser = qwen.serviceConfig.User or \"__absent__\";
  qwenReadOnlyPaths = qwen.serviceConfig.ReadOnlyPaths or [ \"__absent__\" ];
  qwenReadWritePaths = qwen.serviceConfig.ReadWritePaths or [ \"__absent__\" ];
  qwenSupplementaryGroups =
    qwen.serviceConfig.SupplementaryGroups or [ \"__absent__\" ];
}")"

jq -e '
  . as $inference
  | (
  ($inference.qwenUser != "ai-tools")
  and ($inference.qwenReadWritePaths | index($inference.workspace) == null)
  and ($inference.qwenReadOnlyPaths | index($inference.workspace) == null)
  and ($inference.qwenSupplementaryGroups | index("ai-tools") == null)
  )
' <<<"$inference" >/dev/null ||
  {
    echo "❌ The inference unit gained access to the AI workspace." >&2
    jq . <<<"$inference" >&2
    exit 1
  }

echo "AI Tools public host, egress confinement, shared-root ACL, workspace-only writes and data-pool guard passed."
