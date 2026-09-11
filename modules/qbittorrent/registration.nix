{
  ports = {
    qbittorrentWeb = 8085;
    qbittorrentTorrent = 51413;
    oauth2ProxyQbittorrent = 4193;
  };
  homepage = { config, vars }: [
    {
      order = 9;
      id = "torrents";
      name = "Torrents";
      url = "https://torrents.${vars.domain}";
      enabled = builtins.hasAttr "torrents.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "qBittorrent download client for legally sourced media.";
      loginNotes = "Requires media-automation-users through Kanidm.";
      projectUrl = "https://www.qbittorrent.org";
      logoUrl = "/logos/qbittorrent.svg";
      appName = "qbittorrent";
      uploadNotes = "Completed downloads are staged under shared _Downloads.";
      requiredAnyGroups = [ "media-automation-users" ];
    }
  ];
}
