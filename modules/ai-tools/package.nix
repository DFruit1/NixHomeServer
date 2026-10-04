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

    collaboraUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://${vars.networking.loopbackIPv4}:${toString (vars.networking.ports.collaboraOnline or 9980)}";
      defaultText = lib.literalExpression ''
        "http://127.0.0.1:${toString (vars.networking.ports.collaboraOnline or 9980)}"
      '';
      description = ''
        Loopback Collabora Online base URL used by convert_document. This is the
        same instance OpenCloud already runs, reached over loopback, so no
        Collabora setting needs to change.
      '';
    };

    sharedRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}";
      description = ''
        Directory convert_document may read from, and the only path prefix it
        resolves against. Absolute paths, parent traversal and hidden entries
        are rejected, and the canonical result is re-checked against the root so
        a symlink cannot escape.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ appPackages.ai-tools ];
  };
}
