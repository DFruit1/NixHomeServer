#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools jq nix
host="$(test_default_host)"
if [[ "$(flake_eval_json "in builtins.elem \"qwen-27b\" (builtins.getAttr \"$host\" f.lib.nixhomeserverSettings).enabledApps")" != true ]]; then
  echo 'Qwen3.8-27B is disabled; skipping its MCP bridge contract.'
  exit 0
fi

# The point of the bridge is that llama-server reaches ai-tools' tools without
# either app owning a grant the other needs, so the wiring is asserted from both
# ends: the declared child and its environment, and the JSON file llama-server
# actually parses. The ordering edge matters too -- without it the MCP warmup can
# lose the race against ai-tools startup and publish no tools at all.
#
# One evaluation, three cases. extendModules chains cannot be batched into a
# single expression over the same host: the second would resolve against the
# first one's result instead of the flake's, which surfaces as "attribute
# 'config' missing" rather than as what it is. So the base configuration is
# evaluated once, and each disabled-app case overrides the one option that
# decides the integration, using the same trick flake_eval_json uses elsewhere
# in the suite: mkForce on a single option inside extendModules.
#
# The wrapper's own --mcp-servers-config / --cors-origins flags are NOT asserted
# here. ExecStart records only the generated wrapper's store path, so reading the
# flags means inspecting the built wrapper, which needs a Nix build rather than
# an evaluation. That obligation belongs to t_34c52c70.
both_enabled="$(remote_eval_batch_json \
  both="let
    cfg = f.nixosConfigurations.\"$host\".config;
    qwen = cfg.repo.qwen27b;
    llama = cfg.systemd.services.qwen-27b-llama;
  in {
    servers = map (server: { inherit (server) name command args env timeoutMs; }) qwen.mcpServers;
    configFile = builtins.readFile qwen.mcpServersConfigFile;
    corsOrigins = qwen.corsOrigins;
    wants = llama.wants;
    after = llama.after;
  }" \
  aiToolsDisabled="let
    cfg = (f.nixosConfigurations.\"$host\".extendModules { modules = [
      ({ lib, ... }: { repo.aiTools.enable = lib.mkForce false; })
    ]; }).config;
    llama = cfg.systemd.services.qwen-27b-llama;
  in {
    mcpServers = cfg.repo.qwen27b.mcpServers;
    configFileAbsent = cfg.repo.qwen27b.mcpServersConfigFile == null;
    wants = llama.wants;
  }" \
  qwenDisabled="let
    cfg = (f.nixosConfigurations.\"$host\".extendModules { modules = [
      ({ lib, ... }: { repo.qwen27b.enable = lib.mkForce false; })
    ]; }).config;
  in {
    unitExists = cfg.systemd.services ? qwen-27b-llama;
  }")"

both="$(jq -r '.both' <<<"$both_enabled")"
noTools="$(jq -r '.aiToolsDisabled' <<<"$both_enabled")"
noQwen="$(jq -r '.qwenDisabled' <<<"$both_enabled")"

# The generated llama-server MCP config is asserted as its own step because it
# is the file the child process is spawned from, not a rendering of the same
# options: the bridge environment must survive the option -> JSON round trip
# that llama-server performs, not merely be set in Nix.
jq -e '
  (.mcpServers | keys) == ["ai_tools"]
  and (.mcpServers.ai_tools.timeout_ms) >= 60000
  and (.mcpServers.ai_tools.env.AI_TOOLS_TRANSPORT) == "stdio"
  and (.mcpServers.ai_tools.env.AI_TOOLS_BRIDGE_UPSTREAM_URL | startswith("http://127.0.0.1:"))
' <<<"$(jq -r '.configFile' <<<"$both")" >/dev/null || {
  echo "❌ The generated llama-server MCP config is not the expected stdio bridge." >&2
  jq -n --argjson both "$both" '{ both: $both }' >&2
  exit 1
}

jq -e '
  (.servers | length) == 1
  and (.servers[0].name) == "ai_tools"
  and (.servers[0].args == [])
  and (.servers[0].command | endswith("/bin/ai-tools"))
  and (.servers[0].env.AI_TOOLS_TRANSPORT) == "stdio"
  and (.servers[0].env.AI_TOOLS_BRIDGE_UPSTREAM_URL) == "http://127.0.0.1:8097/"
  and (.servers[0].timeoutMs) >= 60000
  and (.corsOrigins) != "*"
  and (.wants | index("ai-tools.service") != null)
  and (.after | index("ai-tools.service") != null)
  and ($noTools.mcpServers == [])
  and $noTools.configFileAbsent
  and (($noTools.wants | index("ai-tools.service")) == null)
  and ($noQwen.unitExists == false)
' --argjson noTools "$noTools" --argjson noQwen "$noQwen" <<<"$both" >/dev/null || {
  echo "❌ The Qwen MCP bridge is not wired as a stdio shim over loopback." >&2
  jq -n --argjson both "$both" --argjson noTools "$noTools" --argjson noQwen "$noQwen" \
    '{ both: $both, aiToolsDisabled: $noTools, qwenDisabled: $noQwen }' >&2
  exit 1
}

echo "Qwen MCP bridge wiring, loopback endpoint and CORS origin passed."