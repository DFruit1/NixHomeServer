{ pkgs, lib, ... }:

let vars = import ../../vars.nix { inherit lib; };
in
{
  services.keycloak = {
    enable   = true;
    hostname = "auth.${vars.domain}";
    database.type = "postgresql";
    database.passwordFile = "/run/secrets/keycloakDbPass";
    initialAdminUser = { username = "admin"; passwordFile = "/run/secrets/keycloakAdminPass"; };
  };
}
