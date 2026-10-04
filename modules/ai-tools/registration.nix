{
  ports = {
    aiTools = 8097;
  };
  homepage = { config, vars }: [
    {
      order = 23;
      id = "ai-tools";
      name = "AI Tools";
      url = "https://tools.${vars.domain}";
      enabled = builtins.hasAttr "tools.${vars.domain}" config.services.caddy.virtualHosts;
      category = "automation";
      description = "Read-only MCP tool endpoint (web search, document conversion).";
      loginNotes = "Sign in with Kanidm; access is granted to ai-users. This host is an MCP endpoint for the local model, not a web interface.";
      logoUrl = "/logos/ai-tools.svg";
      appName = "ai-tools";
      uploadNotes = "Read-only tool server; nothing is uploaded to this service.";
      requiredAnyGroups = [ "ai-users" ];
    }
  ];
}
