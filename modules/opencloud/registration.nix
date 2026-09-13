{
  ports = {
    opencloud = 9200;
    opencloudShareGate = 9201;
    opencloudPublicEdge = 9202;
    collaboraOnline = 9980;
  };
  homepage = { config, vars }: [
    {
      order = 6;
      id = "cloud";
      name = "OpenCloud";
      url = "https://cloud.${vars.domain}";
      enabled = builtins.hasAttr "cloud.${vars.domain}" config.services.caddy.virtualHosts;
      category = "files";
      description = "Collaborative file storage with desktop sync and in-browser office editing.";
      loginNotes = "Sign in with Kanidm; requires the opencloud-users group.";
      projectUrl = "https://opencloud.eu";
      logoUrl = "/logos/opencloud.svg";
      appName = "opencloud";
      uploadNotes = "Sync with the OpenCloud desktop and mobile clients, or edit documents in the browser.";
      requiredAnyGroups = [ "opencloud-users" ];
    }
  ];
}
