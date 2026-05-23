{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
    assertions = [
      {
        assertion = config.age.secrets ? vaultwardenAdminToken;
        message = "Missing vaultwardenAdminToken secret; run scripts/generate-all-secrets.sh";
      }
    ];

    environment.variables = {
      KANIDM_ADMIN_VAULTWARDEN_URL = "https://${vars.vaultwardenDomain}";
      KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE = config.age.secrets.vaultwardenAdminToken.path;
    };
  };
}
