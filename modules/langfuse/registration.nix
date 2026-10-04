{
  ports = {
    langfuse = 3040;
    langfuseWorker = 3041;
    langfuseS3 = 9040;
    langfuseS3Console = 9041;
    langfuseRedis = 6384;
    langfuseClickhouseHttp = 18140;
    langfuseClickhouseTcp = 19140;
  };
  homepage = { config, vars }: [ {
    order = 30;
    id = "langfuse";
    name = "Agent Traces";
    url = "https://langfuse.${vars.domain}";
    enabled = builtins.hasAttr "langfuse.${vars.domain}" config.services.caddy.virtualHosts;
    category = "automation";
    description = "Hermes model latency, usage, errors, and tool execution traces.";
    loginNotes = "Requires langfuse-users through Kanidm, followed by the Langfuse owner login.";
    projectUrl = "https://langfuse.com";
    appName = "langfuse";
    logoUrl = "/logos/ai-tools.svg";
    uploadNotes = "Hermes sends traces automatically; content capture starts in metadata-only mode.";
    requiredAnyGroups = [ "langfuse-users" ];
  } ];
}
