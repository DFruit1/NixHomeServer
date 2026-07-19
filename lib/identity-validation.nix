{
  canaryCollisionSources = vars:
    let
      canaryUser = vars.identity.canaryUser;
      candidateSources = [
        {
          name = "identity.adminUser";
          users = [ vars.identity.adminUser ];
        }
        {
          name = "identity.localAdminUser";
          users = [ vars.identity.localAdminUser ];
        }
        {
          name = "identity.appUsers";
          users = vars.identity.appUsers or [ ];
        }
        {
          name = "identity.appAdminUsers";
          users = vars.identity.appAdminUsers or [ ];
        }
        {
          name = "identity.appUserEmails";
          users = builtins.attrNames (vars.identity.appUserEmails or { });
        }
        {
          name = "backupAccess.adminUsers";
          users = vars.backupAccess.adminUsers or [ ];
        }
        {
          name = "backupAccess.storageUsers";
          users = vars.backupAccess.storageUsers or [ ];
        }
        {
          name = "fileAccess.usbUsers";
          users = vars.fileAccess.usbUsers or [ ];
        }
        {
          name = "seerrAccess.requestManagers";
          users = vars.seerrAccess.requestManagers or [ ];
        }
      ];
    in
    map (source: source.name) (
      builtins.filter (source: builtins.elem canaryUser source.users) candidateSources
    );
}
