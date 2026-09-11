{
  ports = {
    oauth2ProxyDownloads = 4183;
    youtubeDownloader = 8083;
  };
  homepage = { config, vars }: [
    {
      order = 16;
      id = "downloads";
      name = "YouTube Downloads";
      url = "https://ytdownload.${vars.domain}";
      enabled = builtins.hasAttr "ytdownload.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Authenticated yt-dlp queue for audio and video downloads.";
      loginNotes = "Requires downloads-users.";
      projectUrl = "https://github.com/yt-dlp/yt-dlp";
      logoUrl = "/logos/youtube.svg";
      appName = "custom app with yt-dlp";
      uploadNotes = "Downloads land in personal or shared media folders.";
      requiredAnyGroups = [ "downloads-users" ];
    }
  ];
}
