{
  ports = {
    sonarr = 8989;
    oauth2ProxySonarr = 4190;
  };
  homepage = { config, vars }: [
    {
      order = 6;
      id = "sonarr";
      name = "TV Show Downloads";
      url = "https://sonarr.${vars.domain}";
      enabled = builtins.hasAttr "sonarr.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "TV show monitoring and legal download automation.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://sonarr.tv";
      logoUrl = "/logos/sonarr.svg";
      appName = "sonarr";
      uploadNotes = "Imported shows land in shared _Videos/_Shows.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
  ];
}
