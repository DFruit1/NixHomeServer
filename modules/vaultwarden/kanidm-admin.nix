{ config, lib, vars, ... }:

{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
    environment.variables = {
      KANIDM_ADMIN_VAULTWARDEN_URL = "https://${vars.vaultwardenDomain}";
      KANIDM_ADMIN_VAULTWARDEN_ADMIN_TOKEN_FILE = config.age.secrets.vaultwardenAdminToken.path;
    };
  };
}
