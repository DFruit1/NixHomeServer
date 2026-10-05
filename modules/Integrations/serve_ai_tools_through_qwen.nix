{ config, lib, options, ... }:

let
  present = lib.hasAttrByPath [ "repo" "aiTools" ] options
    && lib.hasAttrByPath [ "repo" "qwen27b" ] options;
  cfg = config.repo.aiTools;
  qwen = config.repo.qwen27b;
  bridgeUrl = "http://${cfg.listenAddress}:${toString cfg.port}/";
  # llama-server spawns each declared server once at startup to list its tools,
  # then stops it and respawns on demand per tool call. The name it is declared
  # under becomes the tool-name prefix, so it is part of the tool surface every
  # client of the shared inference endpoint sees; the bridge refuses to serve
  # anything outside the prefix it publishes.
  bridgeName = "ai_tools";
  bridgeCommand = "${cfg.runtime.package}/bin/ai-tools";
  bridgeEnv = {
    AI_TOOLS_TRANSPORT = "stdio";
    AI_TOOLS_BRIDGE_UPSTREAM_URL = bridgeUrl;
    AI_TOOLS_BRIDGE_CONNECT_TIMEOUT_SECS = "10";
    # Matches the per-call timeout declared below, so a wedged tool surfaces as
    # llama-server's own timeout rather than as a killed child mid-answer.
    AI_TOOLS_BRIDGE_CALL_TIMEOUT_SECS = "120";
  };
  # Raised to the bridge's own budget: the upstream default of 30s abandons a
  # document conversion Collabora has not finished and kills the child with it.
  bridgeTimeoutMs = 120000;
in
{
  config = lib.optionalAttrs present (
    lib.mkIf (cfg.enable && qwen.enable) {
      # Only the stdio bridge is declared. ai-tools keeps sole ownership of the
      # shared-root grant, its service account and its sandbox; the child this
      # spawns holds no grant of its own and reaches nothing but loopback.
      repo.qwen27b.mcpServers = [
        {
          name = bridgeName;
          command = bridgeCommand;
          args = [ ];
          env = bridgeEnv;
          timeoutMs = bridgeTimeoutMs;
        }
      ];

      # llama-server discovers MCP tools at startup. Without an ordering edge to
      # ai-tools the warmup can lose the race, and the endpoint then publishes no
      # tools until the unit is restarted by hand.
      systemd.services.qwen-27b-llama = {
        wants = [ "ai-tools.service" ];
        after = [ "ai-tools.service" ];
      };

      assertions = [
        {
          assertion = qwen.corsOrigins != "*";
          message = "repo.qwen27b.corsOrigins must not be '*'; the inference API is unauthenticated.";
        }
      ];
    }
  );
}
