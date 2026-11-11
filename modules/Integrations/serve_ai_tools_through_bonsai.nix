{ config, lib, options, pkgs, vars, ... }:
let
  cfg = config.repo.aiTools;
  bonsai = config.repo.bonsai;
  host = "ai.${vars.domain}";
  # Browser-side MCP calls retain the current user's same-origin SSO cookie.
  # Do not attach private tools to llama-server's identity-free stdio bridge.
  uiConfig = pkgs.writeText "bonsai-app-tools-ui.json" (builtins.toJSON {
    mcpServers = builtins.toJSON [ {
      id = "home-server";
      displayName = "Home server";
      url = "https://${host}/mcp";
      enabled = true;
      useProxy = false;
    } ];
  });
in
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "aiTools" ] options && lib.hasAttrByPath [ "repo" "bonsai" ] options)
    (lib.mkIf (cfg.enable && bonsai.enable) {
      repo.aiTools.chatHost = host;
      repo.bonsai.extraArgs = [ "--ui-config-file" (toString uiConfig) ];
      repo.authGateway.protectedApps.bonsai.authenticatedCaddyConfig = ''
        @chat_mcp path /mcp /mcp/*
        handle @chat_mcp {
          reverse_proxy unix//run/ai-tools-gateway.sock {
            header_up -X-Auth-Request-User
            header_up -X-Auth-Request-Email
            header_up -X-Auth-Request-Groups
            header_up -X-Auth-Request-Preferred-Username
            header_up X-Forwarded-User {http.request.header.X-Auth-Request-User}
            header_up X-Forwarded-Preferred-Username {http.request.header.X-Auth-Request-Preferred-Username}
            header_up -X-Forwarded-Email
            header_up -X-Forwarded-Groups
          }
        }
        handle {
          reverse_proxy http://${bonsai.listenAddress}:${toString bonsai.port}
        }
      '';
      systemd.services.bonsai-llama = {
        wants = [ "ai-tools.service" ];
        after = [ "ai-tools.service" ];
      };
    });
}
