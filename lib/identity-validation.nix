let
  validEmailDomainLabel = label:
    builtins.isString label
    && builtins.stringLength label <= 63
    && builtins.match "[a-z0-9]([a-z0-9-]*[a-z0-9])?" label != null;
in
{
  validEmail = value:
    let
      parts = if builtins.isString value then builtins.filter builtins.isString (builtins.split "@" value) else [ ];
      local = if builtins.length parts == 2 then builtins.elemAt parts 0 else "";
      domain = if builtins.length parts == 2 then builtins.elemAt parts 1 else "";
      domainLabels = builtins.filter builtins.isString (builtins.split "\\." domain);
    in
    builtins.isString value
    && builtins.stringLength value <= 254
    && builtins.length parts == 2
    && builtins.stringLength local <= 64
    && builtins.match "[A-Za-z0-9][A-Za-z0-9._%+-]*" local != null
    && builtins.match ".*[.][.].*" local == null
    && builtins.match ".*[.]" local == null
    && builtins.length domainLabels >= 2
    && builtins.all validEmailDomainLabel domainLabels;

  placeholderEmail = value:
    builtins.isString value
    && (
      builtins.match ".*CHANGE_ME.*" value != null
      || builtins.match ".*@example[.].*" value != null
      || builtins.match ".*[.]test" value != null
    );

  canaryCollisionSources = vars:
    let
      canaryUser = vars.identity.canaryUser;
      listOrEmpty = value: if builtins.isList value then value else [ ];
      attrNamesOrEmpty = value: if builtins.isAttrs value then builtins.attrNames value else [ ];
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
          users = listOrEmpty (vars.identity.appUsers or [ ]);
        }
        {
          name = "identity.appAdminUsers";
          users = listOrEmpty (vars.identity.appAdminUsers or [ ]);
        }
        {
          name = "identity.appUserEmails";
          users = attrNamesOrEmpty (vars.identity.appUserEmails or { });
        }
        {
          name = "backupAccess.adminUsers";
          users = listOrEmpty (vars.backupAccess.adminUsers or [ ]);
        }
        {
          name = "backupAccess.storageUsers";
          users = listOrEmpty (vars.backupAccess.storageUsers or [ ]);
        }
        {
          name = "fileAccess.usbUsers";
          users = listOrEmpty (vars.fileAccess.usbUsers or [ ]);
        }
        {
          name = "seerrAccess.requestManagers";
          users = listOrEmpty (vars.seerrAccess.requestManagers or [ ]);
        }
      ];
    in
    map (source: source.name) (
      builtins.filter (source: builtins.elem canaryUser source.users) candidateSources
    );
}
