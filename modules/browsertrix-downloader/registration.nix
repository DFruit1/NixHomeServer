{
  ports = {
    oauth2ProxyBrowsertrix = 4188;
    browsertrixDownloader = 8088;
  };
  homepage = { config, vars }: [
    {
      order = 20;
      id = "archives";
      name = "Web Archives";
      url = "https://archives.${vars.domain}";
      enabled = builtins.hasAttr "archives.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Queue website crawls and replay the saved .wacz archives in the browser.";
      loginNotes = "Use Kanidm with web-archive-users membership.";
      logoUrl = "/logos/archives.svg";
      appName = "browsertrix-downloader";
      uploadNotes = "Finished crawls are stored in _Shared/_WebArchives and open in the replay view.";
      requiredAnyGroups = [ "web-archive-users" ];
    }
  ];
}
