{ config, lib, pkgsUnstable, vars, ... }:

let
  vaultwardenPort = vars.networking.ports.vaultwarden;
  runtimeDir = "/run/vaultwarden";
  environmentFile = "${runtimeDir}/vaultwarden.env";
in
{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
    services.vaultwarden = {
      enable = true;
      package = pkgsUnstable.vaultwarden;
      webVaultPackage = pkgsUnstable.vaultwarden.webvault;
      dbBackend = "sqlite";
      environmentFile = [ environmentFile ];
      config = {
        DOMAIN = "https://${vars.vaultwardenDomain}";
        ROCKET_ADDRESS = vars.networking.loopbackIPv4;
        ROCKET_PORT = vaultwardenPort;
        ENABLE_WEBSOCKET = true;
        SIGNUPS_ALLOWED = false;
        SIGNUPS_VERIFY = false;
        INVITATIONS_ALLOWED = true;
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
