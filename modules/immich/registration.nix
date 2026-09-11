{
  ports = {
    immich = 2283;
    immichPublicProxy = 3300;
  };
  homepage = { config, vars }: [
    {
      order = 0;
      id = "photos";
      name = "Photos";
      url = "https://photos.${vars.domain}";
      enabled = builtins.hasAttr "photos.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Photo and video library with private login and public share-link support.";
      loginNotes = "Use Kanidm. Public shares use https://sharephotos.${vars.domain}.";
      projectUrl = "https://immich.app";
      logoUrl = "/logos/immich.svg";
      appName = "immich";
      uploadNotes = "Upload through Immich web or the mobile app.";
      requiredAnyGroups = [ "immich-users" ];
    }
  ];
}
