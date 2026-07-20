{ lib }:

{ backupAccess, identity, basePosixGids }:

let
  configuredAdminUsers = backupAccess.adminUsers or [ ];
  configuredStorageUsers = backupAccess.storageUsers or [ ];
  adminUsers =
    if builtins.isList configuredAdminUsers
    then builtins.filter builtins.isString configuredAdminUsers
    else [ ];
  storageUsers =
    if builtins.isList configuredStorageUsers
    then builtins.filter builtins.isString configuredStorageUsers
    else [ ];
  validGroupForRendering = value:
    builtins.isString value
    && builtins.stringLength value <= 64
    && builtins.match "[a-z][a-z0-9._-]*" value != null;
  configuredAdminGroup = backupAccess.adminGroup or null;
  configuredStorageGroup = backupAccess.storageGroup or null;
  configuredStorageGid = backupAccess.storageGid or null;
  adminGroup =
    if validGroupForRendering configuredAdminGroup
    then configuredAdminGroup
    else "invalid-backup-admin-group";
  storageGroup =
    if validGroupForRendering configuredStorageGroup
    then configuredStorageGroup
    else "invalid-backup-storage-group";
  storageGid =
    if builtins.isInt configuredStorageGid
      && configuredStorageGid >= 1000
      && configuredStorageGid <= 59999
    then configuredStorageGid
    else 2005;
  adminMembers = lib.unique ([ identity.adminUser ] ++ adminUsers);
  storageMembers = lib.unique (adminMembers ++ storageUsers);
in
{
  inherit
    adminGroup
    adminMembers
    adminUsers
    configuredAdminUsers
    configuredStorageUsers
    storageGid
    storageGroup
    storageMembers
    storageUsers
    ;

  allUsers = lib.unique (adminMembers ++ storageMembers);
  fileAccessPosixGids = basePosixGids // {
    ${storageGroup} = storageGid;
  };
}
