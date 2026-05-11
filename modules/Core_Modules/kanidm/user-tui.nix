{ config, pkgs, self, vars, ... }:

{
  environment.systemPackages = [
    pkgs.kanidm_1_9
    self.packages.${pkgs.stdenv.hostPlatform.system}.kanidm-admin
  ];

  environment.variables = {
    KANIDM_ADMIN_REPO_ROOT = "/etc/nixos";
    KANIDM_ADMIN_SERVER_URL = vars.kanidmBaseUrl;
    KANIDM_ADMIN_NAME = vars.kanidmAdminUser;
    KANIDM_ADMIN_KANIDM_BIN = "${pkgs.kanidm_1_9}/bin/kanidm";
    KANIDM_ADMIN_NIX_BIN = "${pkgs.nix}/bin/nix";
    KANIDM_ADMIN_VAULTWARDEN_URL = "https://${vars.vaultwardenDomain}";
    KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE =
      config.age.secrets.vaultwardenAdminToken.path;
  };
}
