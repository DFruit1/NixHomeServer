{ lib, config, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
in
{
  users.users.vaultwarden = {
    isSystemUser = true;
    group = "vaultwarden";
    home = "${vars.dataRoot}/vaultwarden"; # for sqlite db
  };

  users.groups.vaultwarden = { };

  ######################################################################
  ## Vaultwarden
  ######################################################################
  services.vaultwarden = {
    enable = true;

    ## ── Core instance paths/ports ────────────────────────────────────
    config = {
      DATA_FOLDER = "${vars.dataRoot}/vaultwarden";
      DOMAIN = "https://vault.${vars.domain}";
      ROCKET_PORT = toString vars.vaultwardenPort;

      ## ── SSO / Kanidm wiring (OIDC) ──────────────────────────────────
      SSO_ENABLED = "true";
      SSO_AUTHORITY = vars.kanidmIssuer;
      SSO_CLIENT_ID = "vaultwarden-web";
      SSO_SCOPES = "openid profile email";
    };

    ## optional: where nightly JSON + attachment backups go
    backupDir = "${vars.dataRoot}/vaultwarden/backups";
  };

  ## pass admin token and client secret without leaking to the Nix store
  systemd.services.vaultwarden.serviceConfig.EnvironmentFile = lib.mkAfter [
    config.age.secrets.vaultwardenAdminToken.path
    config.age.secrets.vaultwardenClientSecret.path
  ];

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/vaultwarden 0700 vaultwarden vaultwarden -"
    "d ${vars.dataRoot}/vaultwarden/backups 0700 vaultwarden vaultwarden -"
  ];

  ## ensure built-in backup uses the custom data directory
  systemd.services.backup-vaultwarden.environment.DATA_FOLDER =
    lib.mkForce "${vars.dataRoot}/vaultwarden";

  ## open the chosen Rocket port in the firewall
  networking.firewall.allowedTCPPorts = [ vars.vaultwardenPort ];
}
