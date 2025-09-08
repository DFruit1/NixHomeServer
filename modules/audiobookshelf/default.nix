{ lib, config, vars, ... }:

{
  services.audiobookshelf = {
    enable = true;
    dataDir = "${vars.dataRoot}/audiobookshelf";
    openFirewall = true; # if you want 8080 exposed
    port = vars.audiobookshelfPort;
  };

  ## Ensure runtime directory exists and is the service cwd
  systemd.services.audiobookshelf.serviceConfig = {
    WorkingDirectory = lib.mkForce "${vars.dataRoot}/audiobookshelf";
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/audiobookshelf 0755 audiobookshelf audiobookshelf -"
  ];

  systemd.services.audiobookshelf.environment = {
    ABS_AUTH_STRATEGY = "oidc";
    ABS_OIDC_PROVIDER_NAME = "Kanidm";
    ABS_OIDC_AUTH_URL = "${vars.kanidmIssuer}/protocol/openid-connect/auth";
    ABS_OIDC_TOKEN_URL = "${vars.kanidmIssuer}/protocol/openid-connect/token";
    ABS_OIDC_CLIENT_ID = "abs-web";
    ABS_OIDC_CLIENT_SECRET_FILE = config.age.secrets.absClientSecret.path;
    ABS_OIDC_SCOPE = "openid profile email";
    ABS_OIDC_LOGOUT_URL = "${vars.kanidmIssuer}/protocol/openid-connect/logout";
    ABS_OIDC_USERNAME_CLAIM = "preferred_username";
  };
}
