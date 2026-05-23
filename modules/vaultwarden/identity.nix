{ config, lib, vars, ... }:

let
  host = "passwords.${vars.domain}";
in

{
  config = {
    assertions = [
      {
        assertion = config.age.secrets ? vaultwardenAdminToken;
        message = "Missing vaultwardenAdminToken secret; run scripts/generate-all-secrets.sh";
      }
    ];

    environment.variables = {
      KANIDM_ADMIN_VAULTWARDEN_URL = "https://${host}";
      KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE = config.age.secrets.vaultwardenAdminToken.path;
    };
  };
}
