{
  ports = {
    paperless = 8000;
  };
  homepage = { config, vars }: [
    {
      order = 1;
      id = "documents";
      name = "Documents";
      url = "https://paperless.${vars.domain}";
      enabled = builtins.hasAttr "paperless.${vars.domain}" config.services.caddy.virtualHosts;
      category = "files";
      description = "Paperless document archive with OCR, search, tags, and exports.";
      loginNotes = "Use Kanidm; first login creates the local account.";
      projectUrl = "https://docs.paperless-ngx.com";
      logoUrl = "/logos/paperless-ngx.svg";
      appName = "paperless-ngx";
      uploadNotes = "Upload PDFs and image documents through Paperless.";
      requiredAnyGroups = [ "paperless-users" ];
    }
  ];
}
