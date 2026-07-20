{ fileAccess }:

let
  groupSpecs = [
    {
      field = "webAccessGroup";
      fallback = "invalid-file-access-web-group";
      gid = 2001;
    }
    {
      field = "sftpAccessGroup";
      fallback = "invalid-file-access-sftp-group";
      gid = 2002;
    }
    {
      field = "sharedAccessGroup";
      fallback = "invalid-file-access-shared-group";
      gid = 2003;
    }
    {
      field = "usbAccessGroup";
      fallback = "invalid-file-access-usb-group";
      gid = 2004;
    }
  ];
  configuredName = spec: fileAccess.${spec.field} or null;
  # Attribute names must be strings before the NixOS assertion phase. Preserve
  # every string verbatim (including semantically invalid ones) so central
  # validation can report the operator field; use a distinct placeholder only
  # for a missing or mistyped value.
  renderableName = spec:
    let
      value = configuredName spec;
    in
    if builtins.isString value then value else spec.fallback;
  toNameEntry = spec: {
    name = spec.field;
    value = configuredName spec;
  };
  toRenderableNameEntry = spec: {
    name = spec.field;
    value = renderableName spec;
  };
  toGidEntry = spec: {
    name = renderableName spec;
    value = spec.gid;
  };
in
{
  configuredGroupNames = builtins.listToAttrs (map toNameEntry groupSpecs);
  renderableGroupNames = builtins.listToAttrs (map toRenderableNameEntry groupSpecs);

  # listToAttrs deliberately makes duplicate operator input total. The central
  # validator rejects the collision with an actionable message before deploy.
  posixGids = builtins.listToAttrs (map toGidEntry groupSpecs);
}
