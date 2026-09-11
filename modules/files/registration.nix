{
  ports = {
    oauth2ProxyFilestash = 4184;
    filestash = 8334;
    filestashTransfers = 9443;
    filesSftp = 2222;
  };
  homepage = { config, vars }: [
    {
      order = 2;
      id = "files";
      name = "Files";
      url = "https://files.${vars.domain}";
      enabled = builtins.hasAttr "files.${vars.domain}" config.services.caddy.virtualHosts;
      category = "files";
      description = "Browser file workspace backed by each user's restricted SFTP root.";
      loginNotes = "Requires ${vars.fileAccess.webAccessGroup} for browser access.";
      projectUrl = "https://www.filestash.app";
      logoUrl = "/logos/filestash.svg";
      appName = "filestash";
      uploadNotes = "Use Files for general uploads and app-specific media folders.";
      requiredAnyGroups = [ vars.fileAccess.webAccessGroup ];
    }
  ];
}
