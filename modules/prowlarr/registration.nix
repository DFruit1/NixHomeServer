{
  ports = {
    prowlarr = 9696;
    oauth2ProxyProwlarr = 4192;
  };
  homepage = { config, vars }: [
    {
      order = 8;
      id = "prowlarr";
      name = "Prowlarr";
      url = "https://prowlarr.${vars.domain}";
      enabled = builtins.hasAttr "prowlarr.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Indexer manager for Sonarr and Radarr.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://prowlarr.com";
      logoUrl = "/logos/prowlarr.png";
      appName = "prowlarr";
      uploadNotes = "Add only legal indexers and sources.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
  ];
}
