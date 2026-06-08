{ pkgs, vars, ... }:

let
  vaultwardenPort = vars.networking.ports.vaultwarden;
  runtimeDir = "/run/vaultwarden";
  environmentFile = "${runtimeDir}/vaultwarden.env";
  host = "passwords.${vars.domain}";
in
{
  config = {
    services.vaultwarden = {
      enable = true;
      package = pkgs.vaultwarden;
      webVaultPackage = pkgs.vaultwarden.webvault;
      dbBackend = "sqlite";
      environmentFile = [ environmentFile ];
      config = {
        DOMAIN = "https://${host}";
        ROCKET_ADDRESS = vars.networking.loopbackIPv4;
        ROCKET_PORT = vaultwardenPort;
        ENABLE_WEBSOCKET = true;
        SIGNUPS_ALLOWED = true;
        SIGNUPS_VERIFY = false;
        INVITATIONS_ALLOWED = false;
        ORG_CREATION_USERS = "none";
        PASSWORD_HINTS_ALLOWED = false;
        SHOW_PASSWORD_HINT = false;
        INVITATION_ORG_NAME = "Passwords";
      };
    };

    systemd.services.vaultwarden = {
      wants = [
        "network-online.target"
        "unbound.service"
        "vaultwarden-secret-materialize.service"
      ];
      after = [
        "network-online.target"
        "unbound.service"
        "vaultwarden-secret-materialize.service"
      ];
    };
  };
}
