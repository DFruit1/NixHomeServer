{ lib, vars, ... }:

let
  cloudHost = "cloud.${vars.domain}";
  appAdminMembers = lib.unique ([ vars.kanidmAdminUser ] ++ vars.kanidmAppAdminUsers);
in
{
  services.kanidm.provision = {
    groups."opencloud-users".members = vars.kanidmAppUsers;
    groups."opencloud-admins".members = appAdminMembers;

    # OpenCloud accepts a single OIDC issuer, so every OpenCloud client (web,
    # desktop, iOS, Android) must use this one public PKCE client. WebFinger
    # advertises it as the client ID for each platform, so all of their
    # redirect URIs must be registered here:
    # - web: the browser callback pages below
    # - desktop: loopback redirects via `enableLocalhostRedirects`
    # - Android/iOS: the apps hardcode an opaque custom scheme. Kanidm masks a
    #   redirect-URI/origin rejection as the generic `InvalidState` error page,
    #   so omitting these makes mobile sign-in fail even though the client is
    #   otherwise correct.
    systems.oauth2.opencloud-web = {
      displayName = "OpenCloud";
      imageFile = ../Core_Modules/kanidm/assets/apps/opencloud.svg;
      public = true;
      enableLocalhostRedirects = true;
      originUrl = [
        "https://${cloudHost}/"
        "https://${cloudHost}/oidc-callback.html"
        "https://${cloudHost}/oidc-silent-redirect.html"
        "oc://android.opencloud.eu"
        "oc://ios.opencloud.eu"
      ];
      originLanding = "https://${cloudHost}";
      preferShortUsername = true;
      # Native shells request offline_access (advertised via WEBFINGER_*_OIDC_
      # CLIENT_SCOPES), and Kanidm denies the whole authorisation if any
      # requested scope is not in the map. Grant it so desktop/mobile sign-in
      # works; the web client does not request it.
      scopeMaps."opencloud-users" = [ "openid" "profile" "email" "offline_access" "opencloud_roles" ];
      scopeMaps."opencloud-admins" = [ "openid" "profile" "email" "offline_access" "opencloud_roles" ];
      claimMaps.opencloud_roles.valuesByGroup."opencloud-users" = [ "opencloudUser" ];
      claimMaps.opencloud_roles.valuesByGroup."opencloud-admins" = [ "opencloudAdmin" ];
    };
  };
}
