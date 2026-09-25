{
  ports = {
    bonsai = 8086;
    bonsaiGate = 8094;
  };
  homepage = { config, vars }: [
    {
      order = 22;
      id = "bonsai";
      name = "Bonsai AI";
      url = "https://ai.${vars.domain}";
      enabled = builtins.hasAttr "ai.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Private local AI chat served by the server's own Bonsai model.";
      loginNotes = "Use Kanidm with ai-users membership; the interface only offers the Bonsai model.";
      logoUrl = "/logos/bonsai.svg";
      appName = "bonsai";
      uploadNotes = "Bonsai stores no files of its own; it answers from the text or images you send in the prompt.";
      requiredAnyGroups = [ "ai-users" ];
    }
  ];
}
