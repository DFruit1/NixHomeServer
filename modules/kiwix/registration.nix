{
  ports = {
    oauth2ProxyKiwix = 4182;
    kiwix = 8081;
    kiwixArchives = 8082;
  };
  homepage = { config, vars }: [
    {
      order = 13;
      id = "wiki";
      name = "Offline Wiki";
      url = "https://wiki.${vars.domain}";
      enabled = builtins.hasAttr "wiki.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Kiwix ZIM library for offline reference material.";
      loginNotes = "Use Kanidm with kiwix-users membership.";
      projectUrl = "https://kiwix.org";
      logoUrl = "/logos/kiwix.svg";
      appName = "kiwix";
      uploadNotes = "Operators upload .zim files to the configured Kiwix library root.";
      requiredAnyGroups = [ "kiwix-users" ];
    }
  ];
}
