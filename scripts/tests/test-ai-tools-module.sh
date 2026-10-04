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
in {
  publicHost = \"tools.\${vars.domain}\";
  envPublicHost = svc.environment.AI_TOOLS_PUBLIC_HOST;
  envListen = svc.environment.AI_TOOLS_LISTEN;
  envSharedRoot = svc.environment.AI_TOOLS_SHARED_ROOT;
  envSearxng = svc.environment.AI_TOOLS_SEARXNG_URL;
  gatewayHost = gateway.host;
  gatewayUpstream = gateway.upstream;
  ipDeny = svc.serviceConfig.IPAddressDeny;
  ipAllow = svc.serviceConfig.IPAddressAllow;
  onFailure = svc.unitConfig.OnFailure;
  alertTarget = cfg.repo.monitoring.failureAlerts.targetUnit;
  requiresMounts = svc.serviceConfig.RequiresMountsFor;
  readOnlyPaths = svc.serviceConfig.ReadOnlyPaths;
  user = svc.serviceConfig.User;
  aclScript = shared.script;
  aclBefore = shared.before;
  guardedService = builtins.elem \"ai-tools\" guarded;
  guardedAcl = builtins.elem \"ai-tools-shared-access\" guarded;
  listen = app.listenAddress;
  port = app.port;
  gatewayMode = cfg.repo.authGateway.mode;
  disableEvaluation = (f.nixosConfigurations.\"$host\".extendModules { modules = [
    ({ lib, ... }: { repo.aiTools.enable = lib.mkForce false; })
  ]; }).config.systemd.services.ai-tools.wantedBy or [];
}")"

jq -e '
  .alertTarget as $alert
  | .envSharedRoot as $shared
  | (
  .envPublicHost == .publicHost
  and .gatewayHost == .publicHost
  and (.envListen | startswith("127.0.0.1:"))
  and (.envSearxng | startswith("http://127.0.0.1:"))
  and (.gatewayUpstream | startswith("http://127.0.0.1:"))
  and (.envSharedRoot | startswith("/"))
  and .ipDeny == "any"
  and .ipAllow == "localhost"
  and (.onFailure | index($alert) != null)
  and (.requiresMounts | index($shared) != null)
  and (.readOnlyPaths | index($shared) != null)
  and .user == "ai-tools"
  and (.aclScript | contains("g:ai-tools:r-x"))
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

echo "AI Tools public host, egress confinement, shared-root ACL and data-pool guard passed."