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

      ## ── Admin panel token (read from Age-decrypted file) ───────────
      ADMIN_TOKEN_FILE = config.age.secrets.vaultwardenAdminToken.path;

      ## ── OIDC / Kanidm wiring ───────────────────────────────────────
      OIDC_ENABLED = "true";
      OIDC_ISSUER = vars.kanidmIssuer;
      OIDC_CLIENT_ID = "vaultwarden-web";
      OIDC_CLIENT_SECRET_FILE = config.age.secrets.vaultwardenClientSecret.path;
      OIDC_SCOPE = "openid profile email";
    };

    ## optional: where nightly JSON + attachment backups go
    backupDir = "${vars.dataRoot}/vaultwarden/backups";
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/vaultwarden 0700 vaultwarden vaultwarden -"
    "d ${vars.dataRoot}/vaultwarden/backups 0700 vaultwarden vaultwarden -"
  ];

  ## open the chosen Rocket port in the firewall
  networking.firewall.allowedTCPPorts = [ vars.vaultwardenPort ];
}
