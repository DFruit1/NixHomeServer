{
  ports = {
    oauth2ProxyMailArchive = 4181;
    mailArchiveUi = 9011;
  };
  homepage = { config, vars }: [
    {
      order = 15;
      id = "emails";
      name = "Mail Archive";
      url = "https://emails.${vars.domain}";
      enabled = builtins.hasAttr "emails.${vars.domain}" config.services.caddy.virtualHosts;
      category = "knowledge";
      description = "Private mail search, attachment export, and Paperless handoff.";
      loginNotes = "Requires mail-archive-users.";
      logoUrl = "/logos/mail-archive-ui.svg";
      appName = "custom app with notmuch / maildir";
      uploadNotes = "Synced mail appears as visible .eml mirrors under _Emails.";
      requiredAnyGroups = [ "mail-archive-users" ];
    }
  ];
}
