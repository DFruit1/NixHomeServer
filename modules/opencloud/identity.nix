{ lib, vars, ... }:

let
  cloudHost = "cloud.${vars.domain}";
  appAdminMembers = lib.unique ([ vars.kanidmAdminUser ] ++ vars.kanidmAppAdminUsers);
in
{
  services.kanidm.provision = {
    groups."opencloud-users".members = vars.kanidmAppUsers;
    groups."opencloud-admins".members = appAdminMembers;

    # OpenCloud accepts a single OIDC issuer and maps every client through the
    # same public PKCE client. `enableLocalhostRedirects` lets the desktop
    # client complete its loopback redirect without enumerating ports.
    systems.oauth2.opencloud-web = {
      displayName = "OpenCloud";
      imageFile = ../Core_Modules/kanidm/assets/apps/opencloud.svg;
      public = true;
      enableLocalhostRedirects = true;
      originUrl = [
        "https://${cloudHost}/"
        "https://${cloudHost}/oidc-callback.html"
        "https://${cloudHost}/oidc-silent-redirect.html"
      ];
      originLanding = "https://${cloudHost}";
      preferShortUsername = true;
      scopeMaps."opencloud-users" = [ "openid" "profile" "email" "opencloud_roles" ];
      scopeMaps."opencloud-admins" = [ "openid" "profile" "email" "opencloud_roles" ];
      claimMaps.opencloud_roles.valuesByGroup."opencloud-users" = [ "opencloudUser" ];
      claimMaps.opencloud_roles.valuesByGroup."opencloud-admins" = [ "opencloudAdmin" ];
    };
  };
}
