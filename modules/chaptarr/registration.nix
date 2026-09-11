{
  ports = {
    chaptarr = 8789;
  };
  homepage = { config, vars }: [
    {
      order = 5;
      id = "chaptarr";
      name = "Book Downloads";
      url = "https://chaptarr.${vars.domain}";
      enabled = builtins.hasAttr "chaptarr.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Audiobook and ebook monitoring, metadata, and legal download automation.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://github.com/Chaptarr/chaptarr";
      logoUrl = "/logos/chaptarr.svg";
      appName = "chaptarr";
      uploadNotes = "Imported audiobooks land in Audiobookshelf; ebooks land in Kavita.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
  ];
}
