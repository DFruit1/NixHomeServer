{
  ports = {
    radarr = 7878;
    oauth2ProxyRadarr = 4191;
  };
  homepage = { config, vars }: [
    {
      order = 7;
      id = "radarr";
      name = "Movie Downloads";
      url = "https://radarr.${vars.domain}";
      enabled = builtins.hasAttr "radarr.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Movie monitoring and legal download automation.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://radarr.video";
      logoUrl = "/logos/radarr.svg";
      appName = "radarr";
      uploadNotes = "Imported movies land in shared _Videos/_Movies.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
  ];
}
