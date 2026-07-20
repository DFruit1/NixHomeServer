{ lib }:

{ identity
, fileAccess ? { }
, monitoringAccess ? { }
, seerrAccess ? { }
,
}:

let
  identityValidation = import ./identity-validation.nix;
  nameValidation = import ./name-validation.nix { inherit lib; };

  configuredAppUsers = identity.appUsers or [ ];
  configuredAppAdminUsers = identity.appAdminUsers or [ ];
  configuredAppUserEmails = identity.appUserEmails or { };
  configuredAdminMailAddresses = identity.adminMailAddresses or [ ];
  configuredMonitoringUsers = monitoringAccess.users or [ ];
  configuredSeerrRequestManagers = seerrAccess.requestManagers or [ ];
  configuredUsbUsers = fileAccess.usbUsers or [ ];

  renderableUsers = value:
    if builtins.isList value then
      builtins.filter nameValidation.validKanidmUser value
    else
      [ ];
in
{
  inherit
    configuredAdminMailAddresses
    configuredAppAdminUsers
    configuredAppUserEmails
    configuredAppUsers
    configuredMonitoringUsers
    configuredSeerrRequestManagers
    configuredUsbUsers
    ;

  # Only validated values reach dynamic provision attributes and generated
  # shell fragments. Central validation still sees every configured value
  # above and reports the operator-facing error instead of an evaluator crash.
  appUsers = lib.unique (
    [
      identity.adminUser
      identity.canaryUser
    ]
    ++ renderableUsers configuredAppUsers
    ++ renderableUsers configuredAppAdminUsers
  );
  appAdminUsers = lib.unique (
    [ identity.adminUser ]
    ++ renderableUsers configuredAppAdminUsers
  );
  appUserEmails =
    if builtins.isAttrs configuredAppUserEmails then
      lib.filterAttrs
        (user: email:
          nameValidation.validKanidmUser user
          && identityValidation.validEmail email)
        configuredAppUserEmails
    else
      { };
  adminMailAddresses = builtins.filter identityValidation.validEmail
    (if builtins.isList configuredAdminMailAddresses then configuredAdminMailAddresses else [ ]);
  monitoringUsers = renderableUsers configuredMonitoringUsers;
  seerrRequestManagers = renderableUsers configuredSeerrRequestManagers;
  usbUsers = renderableUsers configuredUsbUsers;
}
