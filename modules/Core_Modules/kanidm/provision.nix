{ config, lib, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  appPersonNames = lib.unique (vars.kanidmAppUsers ++ vars.kanidmAppAdminUsers ++ vars.kanidmBackupAdminUsers);
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  mkAppPerson = user: {
    displayName = user;
  } // lib.optionalAttrs (builtins.hasAttr user vars.kanidmAppUserEmails) {
    mailAddresses = [ vars.kanidmAppUserEmails.${user} ];
  };
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

    persons =
      (lib.genAttrs appPersonNames mkAppPerson)
      // {
        ${vars.kanidmAdminUser} = {
          displayName = vars.kanidmAdminUser;
          mailAddresses = adminMailAddresses;
        };
      };

    groups = {
      # Keep the builtin group in the provision inventory so post-start
      # reconciliation does not try to delete it as an orphaned entity.
      "domain_admins" = mkManualGroup [ ];
      "app-admin" = mkManualGroup vars.kanidmAppAdminUsers;
      ${vars.backupAccess.adminGroup} = mkManualGroup vars.kanidmBackupAdminUsers;
      ${vars.fileAccess.webAccessGroup} = mkManualGroup vars.kanidmAppUsers;
      ${vars.fileAccess.sftpAccessGroup} = mkManualGroup (vars.filesSftpUsers or [ ]);
      ${vars.fileAccess.sharedAccessGroup} = mkManualGroup [ ];
      users = mkManualGroup vars.kanidmAppUsers;
    };
  };
}
