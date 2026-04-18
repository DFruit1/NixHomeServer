{ pkgs, lib, vars, ... }:

{
  services.keycloak = {
    enable   = true;
    hostname = "auth.${vars.domain}";
    database.type = "postgresql";
    database.passwordFile = "/run/secrets/keycloakDbPass";
    initialAdminUser = { username = "admin"; passwordFile = "/run/secrets/keycloakAdminPass"; };
  };
}
