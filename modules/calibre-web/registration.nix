{
  ports = {
    oauth2ProxyCalibreWeb = 4189;
    calibreWeb = 8095;
  };
  homepage = { config, vars }: [
    {
      order = 18;
      id = "calibre";
      name = "Technical Library";
      url = "https://calibre.${vars.domain}";
      enabled = builtins.hasAttr "calibre.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Searchable Calibre catalogue of technical books and reference manuals.";
      loginNotes = "Use Kanidm for gateway access, then the Calibre-Web local account for uploads and management.";
      projectUrl = "https://github.com/janeczku/calibre-web";
      logoUrl = "/logos/calibre-web.svg";
      appName = "calibre-web";
      uploadNotes = "Upload technical books in the Calibre-Web UI; the shared library is indexed by Search.";
      requiredAnyGroups = [ "calibre-web-users" ];
    }
  ];
}
