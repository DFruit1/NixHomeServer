{
  ports = {
    search = 8092;
    searchSolr = 8983;
  };
  homepage = { config, vars }: [
    {
      order = 21;
      id = "search";
      name = "Search";
      url = "https://search.${vars.domain}";
      enabled = builtins.hasAttr "search.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "One query across documents, mail, feeds, archives, and media libraries.";
      loginNotes = "Requires search-admins membership; every member searches every indexed source.";
      logoUrl = "/logos/search.svg";
      appName = "search";
      uploadNotes = "Search indexes other apps; add content there and let the hourly index run pick it up.";
      requiredAnyGroups = [ "search-admins" ];
    }
  ];
}
