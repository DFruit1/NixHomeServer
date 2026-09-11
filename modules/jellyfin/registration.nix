{
  mediaManager = { label = "Jellyfin"; capabilities = [ "library-refresh" ]; };
  ports = {
    jellyfin = 8096;
    jellyfinDiscovery = 7359;
  };
  homepage = { config, vars }: [
    {
      order = 4;
      id = "videos";
      name = "Videos";
      url = "https://videos.${vars.domain}";
      enabled = builtins.hasAttr "videos.${vars.domain}" config.services.caddy.virtualHosts;
      category = "media";
      description = "Metadata-rich movie and show libraries.";
      loginNotes = "In a browser, choose “Sign in with Kanidm”. In a TV or native app, choose Quick Connect, note the six-digit code, then authorize it at https://videos.${vars.domain}/sso/OIDC/QuickConnect/kanidm in any browser. A native app’s password box accepts only the separate Jellyfin local password; the Kanidm password will not work there. If discovery finds nothing, keep the client on the same IPv4 LAN, disable Wi-Fi client isolation, and check the client firewall guidance in Admin tools.";
      projectUrl = "https://jellyfin.org";
      logoUrl = "/logos/jellyfin.svg";
      appName = "jellyfin";
      uploadNotes = "Place movies under _Videos/_Movies and series under _Videos/_Shows.";
      requiredAnyGroups = [ "jellyfin-users" ];
    }
  ];
}
