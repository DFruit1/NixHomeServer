{
  ports = {
    qwen27b = 8093;
  };
  homepage = { config, vars }: [
    {
      order = 22;
      id = "qwen-27b";
      name = "Local AI";
      url = "https://ai.${vars.domain}";
      enabled = builtins.hasAttr "ai.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Private chat with the server's local Qwen3.8-27B model.";
      loginNotes = "Sign in with Kanidm; access is granted to ai-users.";
      logoUrl = "/logos/qwen-27b.svg";
      appName = "qwen-27b";
      uploadNotes = "Prompts and attachments are processed by the server's local model.";
      requiredAnyGroups = [ "ai-users" ];
    }
  ];
}