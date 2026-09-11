{
  mediaManager = { label = "Audiobookshelf"; capabilities = [ "library-refresh" ]; };
  ports = {
    audiobookshelf = 13378;
  };
  homepage = { config, vars }: [
    {
      order = 3;
      id = "audiobooks";
      name = "Audiobooks";
      url = "https://audiobooks.${vars.domain}/audiobookshelf/";
      enabled = builtins.hasAttr "audiobooks.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Audiobooks and long-form audio libraries.";
      loginNotes = "Use Kanidm. The configured server operator owns the Audiobookshelf root account; app-admin does not grant Audiobookshelf administrator rights.";
      projectUrl = "https://www.audiobookshelf.org";
      logoUrl = "/logos/audiobookshelf.svg";
      appName = "audiobookshelf";
      uploadNotes = "Place audiobook folders under _Audiobooks.";
      requiredAnyGroups = [ "audiobookshelf-users" ];
    }
  ];
}
