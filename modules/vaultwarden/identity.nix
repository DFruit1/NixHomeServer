{ config, vars, ... }:

let
  host = "passwords.${vars.domain}";
in

{
  config = {
    environment.variables = {
      KANIDM_ADMIN_VAULTWARDEN_URL = "https://${host}";
      KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE = config.age.secrets.vaultwardenAdminToken.path;
    };
  };
}
