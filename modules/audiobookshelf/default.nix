{ lib, config, vars, ... }:

let
  absClientId = "abs-web";
  absIssuer = "https://${vars.kanidmDomain}/oauth2/openid/${absClientId}";
  kanidmAuthoriseEndpoint = "https://${vars.kanidmDomain}/oauth2/authorise";
  kanidmTokenEndpoint = "https://${vars.kanidmDomain}/oauth2/token";
  kanidmLogoutEndpoint = "${absIssuer}/logout";
in
{
  services.audiobookshelf = {
    enable = true;
    host = "127.0.0.1";
    port = vars.audiobookshelfPort;
  };

  systemd.services.audiobookshelf.environment = {
    ABS_BIND_ADDRESS = "127.0.0.1";
    ABS_AUTH_STRATEGY = "oidc";
    ABS_OIDC_PROVIDER_NAME = "Kanidm";
    ABS_OIDC_AUTH_URL = kanidmAuthoriseEndpoint;
    ABS_OIDC_TOKEN_URL = kanidmTokenEndpoint;
    ABS_OIDC_CLIENT_ID = absClientId;
    ABS_OIDC_CLIENT_SECRET_FILE = config.age.secrets.absClientSecret.path;
    ABS_OIDC_SCOPE = "openid profile email";
    ABS_OIDC_LOGOUT_URL = kanidmLogoutEndpoint;
    ABS_OIDC_USERNAME_CLAIM = "preferred_username";
  };

  systemd.services.audiobookshelf.serviceConfig.AppArmorProfile = "generated-audiobookshelf";
}
