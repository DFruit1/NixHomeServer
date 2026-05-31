{ appPackages, config, lib, pkgs, vars, ... }:

let
  systemPackages =
    [
      appPackages.kanidm-admin
    ];
  rootHelper = "/run/current-system/sw/bin/kanidm-admin-root";
  allowedSecretPaths =
    lib.optional
      (builtins.hasAttr "vaultwardenAdminToken" config.age.secrets)
      config.age.secrets.vaultwardenAdminToken.path;
in
{
  environment.systemPackages = systemPackages;

  environment.etc."kanidm-admin-root/allowed-secret-paths".text =
    (lib.concatMapStringsSep "\n" toString allowedSecretPaths)
    + lib.optionalString (allowedSecretPaths != [ ]) "\n";

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm-admin 0700 ${vars.localAdminUser} users -"
    "d /var/lib/kanidm-admin/history 0700 ${vars.localAdminUser} users -"
  ];

  # kanidm-admin local runtime actions use this exact helper contract. The
  # broader deploy/bootstrap sudo policy is documented in base-system and is
  # reported by `kanidm-admin doctor --deep` until deploy sudo is narrowed.
  security.sudo.extraRules = [
    {
      users = [ vars.localAdminUser ];
      commands = [
        {
          command = "${rootHelper} *";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  environment.variables = {
    KANIDM_ADMIN_REPO_ROOT = "/etc/nixos";
    KANIDM_ADMIN_SERVER_URL = vars.kanidmBaseUrl;
    KANIDM_ADMIN_NAME = vars.kanidmAdminUser;
    KANIDM_ADMIN_KANIDM_BIN = "${pkgs.kanidm_1_9}/bin/kanidm";
    KANIDM_ADMIN_NIX_BIN = "${pkgs.nix}/bin/nix";
    KANIDM_ADMIN_HISTORY_DIR = "/var/lib/kanidm-admin/history";
    KANIDM_ADMIN_ROOT_HELPER = rootHelper;
    KANIDM_ADMIN_ROOT_ALLOWED_SECRET_PATHS_FILE = "/etc/kanidm-admin-root/allowed-secret-paths";
  };
}
