{ config, lib, vars, appPackages, ... }:

let
  cfg = config.repo.aiTools;
in
{
  options.repo.aiTools = {
    enable = lib.mkEnableOption ''
      Read-only MCP tool server for the llama.cpp web UI. Tools are attached
      per client, so the shared inference endpoint keeps serving other
      consumers with their own tool choices.
    '';

    runtime = {
      package = lib.mkOption {
        type = lib.types.package;
        default = appPackages.ai-tools;
        readOnly = true;
        description = "Pinned ai-tools MCP server package.";
      };
    };

    searxngUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${vars.networking.loopbackIPv4}:${toString (vars.networking.ports.searxng or 8098)}";
      defaultText = lib.literalExpression ''
        "http://127.0.0.1:${toString (vars.networking.ports.searxng or 8098)}"
      '';
      description = "Base URL of the loopback SearXNG instance backing web_search.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ appPackages.ai-tools ];
  };
}
