{ config, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  mkManualGroup =
    members:
    {
      inherit members;
      overwriteMembers = false;
    };
in
{
  services.kanidm.provision = {
    enable = true;
    idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
    adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
    instanceUrl = kanidmCliUrl;

    persons.${vars.kanidmAdminUser} = {
      displayName = vars.kanidmAdminUser;
      mailAddresses = [ vars.kanidmAdminEmail ];
    };

    groups = {
      # Keep the builtin group in the provision inventory so post-start
      # reconciliation does not try to delete it as an orphaned entity.
      "domain_admins" = mkManualGroup [ ];
      "app-admin" = mkManualGroup [ vars.kanidmAdminUser ];
      users = mkManualGroup [ vars.kanidmAdminUser ];
    };
  };
}
