{
  ports = {
    vaultwarden = 8222;
  };
  homepage = { config, vars }: [
    {
      order = 17;
      id = "passwords";
      name = "Passwords";
      url = "https://passwords.${vars.domain}";
      enabled = builtins.hasAttr "passwords.${vars.domain}" config.services.caddy.virtualHosts;
      category = "identity";
      description = "Shared password manager for server and account credentials.";
      loginNotes = "Vaultwarden is self-service: open the signup page on first visit and register with your local account email.";
      projectUrl = "https://github.com/dani-garcia/vaultwarden";
      logoUrl = "/logos/vaultwarden.svg";
      appName = "vaultwarden";
      uploadNotes = "Store Kanidm credentials, recovery codes, and app-local passwords here.";
    }
  ];
}
