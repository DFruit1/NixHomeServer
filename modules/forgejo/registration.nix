{
  ports = {
    forgejo = 3000;
    forgejoSsh = 2223;
  };
  homepage = { config, vars }: [
    {
      order = 19;
      id = "git";
      name = "Git";
      url = "https://git.${vars.domain}";
      enabled = builtins.hasAttr "git.${vars.domain}" config.services.caddy.virtualHosts;
      category = "operations";
      description = "Private git forge for personal repositories and pull mirrors of upstream projects.";
      loginNotes = "Use Kanidm; the first sign-in creates the Forgejo account. Git over SSH uses port ${toString vars.networking.ports.forgejoSsh}.";
      projectUrl = "https://forgejo.org";
      logoUrl = "/logos/forgejo.svg";
      appName = "forgejo";
      uploadNotes = "Push to git.${vars.domain} over HTTPS or SSH; declared GitHub mirrors sync automatically.";
      requiredAnyGroups = [ "forgejo-users" ];
    }
  ];
}
