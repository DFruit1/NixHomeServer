{
  ports = {
    aiTools = 8097;
    searxng = 8098;
  };
  homepage = { config, vars }: [
    {
      order = 23;
      id = "ai-tools";
      name = "AI Tools";
      url = "https://tools.${vars.domain}";
      enabled = builtins.hasAttr "tools.${vars.domain}" config.services.caddy.virtualHosts;
      category = "automation";
      description = "Read-only MCP tools (web search) for the local model.";
      loginNotes = "Sign in with Kanidm; access is granted to ai-users.";
      logoUrl = "/logos/ai-tools.svg";
      appName = "ai-tools";
      uploadNotes = "Read-only tool server; nothing is uploaded to this service.";
      requiredAnyGroups = [ "ai-users" ];
    }
  ];
}
