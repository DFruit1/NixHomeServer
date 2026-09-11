{
  mediaManager = { label = "Kavita"; capabilities = [ "library-refresh" ]; };
  ports = {
    kavita = 5000;
  };
  homepage = { config, vars }: [
    {
      order = 12;
      id = "books";
      name = "Books";
      url = "https://books.${vars.domain}";
      enabled = builtins.hasAttr "books.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Ebooks, comics, and manga in Kavita.";
      loginNotes = "Use Kanidm; first login provisions the local account.";
      projectUrl = "https://www.kavitareader.com";
      logoUrl = "/logos/kavita.svg";
      appName = "kavita";
      uploadNotes = "Place books under _Books/_Ebooks, _Comics, or _Manga.";
      requiredAnyGroups = [ "kavita-users" ];
    }
  ];
}
