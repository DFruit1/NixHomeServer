{ backupAccess, basePosixGids }:

let
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
in
{
  inherit
    adminGroup
    storageGid
    storageGroup
    ;

  fileAccessPosixGids = basePosixGids // {
    ${storageGroup} = storageGid;
  };
}
