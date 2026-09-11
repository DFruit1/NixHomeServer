{
  ports = { };
  homepage = { config, vars }: [
    {
      order = 14;
      id = "feeds";
      name = "Feeds";
      url = "https://rss.${vars.domain}";
      enabled = builtins.hasAttr "rss.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Private RSS and Atom subscriptions with a separate feed library for each user.";
      loginNotes = "Use Kanidm with freshrss-users membership; first login creates the FreshRSS account.";
      projectUrl = "https://freshrss.org";
      logoUrl = "/logos/freshrss.svg";
      appName = "freshrss";
      uploadNotes = "Add feed URLs or import an OPML subscription list from FreshRSS settings.";
      requiredAnyGroups = [ "freshrss-users" ];
    }
  ];
}
