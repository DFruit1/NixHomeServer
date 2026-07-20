{ config, lib, vars, ... }:

let
  networkValidation = import ../../../lib/network-validation.nix { inherit lib; };
  identityValidation = import ../../../lib/identity-validation.nix;
  nameValidation = import ../../../lib/name-validation.nix { inherit lib; };
  storageValidation = import ../../../lib/storage-validation.nix { inherit lib; };
  backupAdminGroupRaw = vars.backupAccess.adminGroup or null;
  backupStorageGroupRaw = vars.backupAccess.storageGroup or null;
  backupStorageGidRaw = vars.backupAccess.storageGid or null;
  backupAdminUsersRaw = vars.backupAccess.adminUsers or [ ];
  backupStorageUsersRaw = vars.backupAccess.storageUsers or [ ];
  identityAppUsersRaw = vars.identity.appUsers or [ ];
  identityAppAdminUsersRaw = vars.identity.appAdminUsers or [ ];
  identityAppUserEmailsRaw = vars.identity.appUserEmails or { };
  identityAdminMailAddressesRaw = vars.identity.adminMailAddresses or [ ];
  monitoringAccessUsersRaw = vars.monitoringAccess.users or [ ];
  seerrRequestManagersRaw = vars.seerrAccess.requestManagers or [ ];
  fileAccessUsbUsersRaw = vars.fileAccess.usbUsers or [ ];
  configuredKanidmUserLists = [
    {
      field = "identity.appUsers";
      value = identityAppUsersRaw;
    }
    {
      field = "identity.appAdminUsers";
      value = identityAppAdminUsersRaw;
    }
    {
      field = "monitoringAccess.users";
      value = monitoringAccessUsersRaw;
    }
    {
      field = "seerrAccess.requestManagers";
      value = seerrRequestManagersRaw;
    }
    {
      field = "fileAccess.usbUsers";
      value = fileAccessUsbUsersRaw;
    }
  ];
  invalidConfiguredKanidmUserLists = map
    (input: input // {
      invalidMembers =
        if builtins.isList input.value then
          builtins.filter (member: !nameValidation.validKanidmUser member) input.value
        else
          [ ];
    })
    configuredKanidmUserLists;
  identityUserListTypeAssertions = map
    (input: {
      assertion = builtins.isList input.value;
      message = "nixhomeserver: ${input.field} must be a list of Kanidm usernames, for example [ \"alice\" ]; do not use a bare string or attribute set.";
    })
    configuredKanidmUserLists;
  identityUserListMemberAssertions = map
    (input: {
      assertion = !builtins.isList input.value || input.invalidMembers == [ ];
      message = "nixhomeserver: ${input.field} entries must be canonical Kanidm usernames: start with a lowercase letter, use only lowercase letters, digits, dot, underscore, or hyphen, and use at most 64 characters.";
    })
    invalidConfiguredKanidmUserLists;
  identityAppUserEmailsAreAttrs = builtins.isAttrs identityAppUserEmailsRaw;
  identityAppUserEmails = if identityAppUserEmailsAreAttrs then identityAppUserEmailsRaw else { };
  invalidIdentityAppUserEmailNames = builtins.filter
    (user: !nameValidation.validKanidmUser user)
    (builtins.attrNames identityAppUserEmails);
  invalidIdentityAppUserEmailValues = builtins.attrNames (lib.filterAttrs
    (_: email: !identityValidation.validEmail email)
    identityAppUserEmails);
  identityAdminMailAddressesAreList = builtins.isList identityAdminMailAddressesRaw;
  invalidIdentityAdminMailAddresses =
    if identityAdminMailAddressesAreList then
      builtins.filter (email: !identityValidation.validEmail email) identityAdminMailAddressesRaw
    else
      [ ];
  validBackupAdminUsers =
    builtins.isList backupAdminUsersRaw
    && lib.all nameValidation.validKanidmUser backupAdminUsersRaw;
  validBackupStorageUsers =
    builtins.isList backupStorageUsersRaw
    && lib.all nameValidation.validKanidmUser backupStorageUsersRaw;
  overlappingBackupAccessUsers = lib.intersectLists vars.backupAdminUsers vars.backupStorageUsers;
  allowPlaceholders = vars.validation.allowPlaceholders or false;
  containsChangeMe = value: lib.hasInfix "CHANGE_ME" (toString value);
  externallyBoundPorts = lib.filterAttrs (name: _: !(lib.hasSuffix "Container" name)) vars.networking.ports;
  kopiaPort = vars.networking.ports.kopia;
  kopiaAuthProxyPort = if builtins.isInt kopiaPort then kopiaPort + 1 else -1;
  endpointPorts = externallyBoundPorts // {
    # Kopia's authenticated Caddy bridge is derived rather than explicitly
    # configured, so it must participate in the same collision/range checks.
    kopiaAuthProxy = kopiaAuthProxyPort;
  };
  portValues = lib.attrValues endpointPorts;
  uniquePortValues = lib.unique portValues;
  invalidEndpointPorts = lib.filterAttrs (_: port: !(builtins.isInt port) || port < 1 || port > 65535) endpointPorts;
  caddyHosts = builtins.attrNames config.services.caddy.virtualHosts;
  cloudflareHosts = builtins.attrNames config.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
  privateDnsHosts = config.services.unbound.privateHosts;
  privateDnsHostNames = builtins.attrNames privateDnsHosts;
  supportedDnsPrivacyModes = [ "encrypted-only" ];
  lanDnsHostsRaw = vars.networking.dns.lanHosts or { };
  lanDnsHostsAreAttrs = builtins.isAttrs lanDnsHostsRaw;
  lanDnsHosts = if lanDnsHostsAreAttrs then lanDnsHostsRaw else { };
  lanDnsHostNames = builtins.attrNames lanDnsHosts;
  normaliseConfiguredDnsName = name:
    if lib.hasSuffix "." name then lib.removeSuffix "." name else name;
  invalidLanDnsHostNames = lib.filter
    (name: !nameValidation.validDnsName (normaliseConfiguredDnsName name))
    lanDnsHostNames;
  invalidLanDnsHostAddressNames = lib.filter
    (name: !networkValidation.validIPv4 lanDnsHosts.${name})
    lanDnsHostNames;
  canValidateLanDnsHostMembership =
    networkValidation.validIPv4 vars.serverLanIP
    && builtins.isInt vars.networking.lan.prefixLength
    && vars.networking.lan.prefixLength >= 1
    && vars.networking.lan.prefixLength <= 30;
  offLanDnsHostAddressNames =
    if canValidateLanDnsHostMembership then
      lib.filter
        (name:
          let
            address = lanDnsHosts.${name};
          in
          networkValidation.validIPv4 address
          && !networkValidation.usableIPv4InSubnet address vars.serverLanIP vars.networking.lan.prefixLength)
        lanDnsHostNames
    else
      [ ];
  domainSuffix = ".${vars.domain}";
  lanDomainSuffix = ".${vars.networking.dns.lanDomain}";
  localAliasCandidates =
    builtins.filter
      (
        name:
        let
          short = lib.removeSuffix domainSuffix name;
        in
        lib.hasSuffix domainSuffix name
        && name != vars.domain
        && name != "www.${vars.domain}"
        && name != vars.kanidmDomain
        && short != ""
        && !lib.hasInfix "." short
      )
      caddyHosts;
  allowedLanAliasHosts =
    map (name: "http://${lib.removeSuffix domainSuffix name}") localAliasCandidates
    ++ map (name: "http://${lib.removeSuffix domainSuffix name}${lanDomainSuffix}") localAliasCandidates;
  coreHosts = [
    vars.domain
    "www.${vars.domain}"
    vars.kanidmDomain
  ];
  invalidHostNames =
    lib.filter
      (name:
        let
          isAllowedLanAlias = builtins.elem name allowedLanAliasHosts;
        in
        name == ""
        || (!isAllowedLanAlias && name != "default" && !nameValidation.validDnsName name))
      (caddyHosts ++ cloudflareHosts ++ privateDnsHostNames);
  offDomainAppHosts =
    lib.filter
      (
        name:
        !(builtins.elem name coreHosts)
        && !(lib.hasSuffix ".${vars.domain}" name)
        && !builtins.elem name allowedLanAliasHosts
      )
      caddyHosts;
  cloudflareWithoutCaddy =
    lib.filter
      (name: !(builtins.hasAttr name config.services.caddy.virtualHosts))
      cloudflareHosts;
  invalidDnsHosts =
    lib.filter
      (name:
        let
          host = privateDnsHosts.${name};
        in
        !host.publishOnLan && !host.publishOnNetbird)
      privateDnsHostNames;
  toList = value: if builtins.isList value then value else [ value ];
  oauth2Clients = config.services.kanidm.provision.systems.oauth2;
  oauth2ClientNames = builtins.attrNames oauth2Clients;
  oauth2UrlValues = client:
    (toList client.originUrl)
    ++ lib.optional ((client.originLanding or null) != null) client.originLanding
    ++ (client.redirects or [ ]);
  isAllowedOauth2Url = url:
    lib.hasPrefix "https://" url
    || url == "app.immich:///oauth-callback";
  insecureOauth2Urls = lib.concatMap
    (name:
      let
        client = oauth2Clients.${name};
      in
      lib.optionals (!(client.allowInsecureUrls or false))
        (map
          (url: "${name}: ${url}")
          (lib.filter (url: !(isAllowedOauth2Url url)) (oauth2UrlValues client))))
    oauth2ClientNames;
  hostIdChars = lib.stringToCharacters vars.hostId;
  hexChars = lib.stringToCharacters "0123456789abcdef";
  validHostId =
    builtins.stringLength vars.hostId == 8
    && lib.all (char: builtins.elem char hexChars) hostIdChars;
  kanidmAdminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  kanidmAppUserMailAddresses = lib.attrValues vars.kanidmAppUserEmails;
  configuredMailAddresses = kanidmAdminMailAddresses ++ kanidmAppUserMailAddresses;
  invalidMailAddresses = lib.filter (email: !identityValidation.validEmail email) configuredMailAddresses;
  placeholderMailAddresses = lib.filter identityValidation.placeholderEmail configuredMailAddresses;
  kanidmAdminAppUserMailConflicts =
    lib.intersectLists kanidmAdminMailAddresses kanidmAppUserMailAddresses;
  kanidmProvision = config.services.kanidm.provision;
  kanidmProvisionedPersons = kanidmProvision.persons or { };
  kanidmProvisionedGroups = kanidmProvision.groups or { };
  kanidmPersonNames = builtins.attrNames kanidmProvisionedPersons;
  kanidmGroupNames = builtins.attrNames kanidmProvisionedGroups;
  kanidmGroupMemberships = lib.concatMap
    (groupName:
      map
        (memberName: {
          inherit groupName memberName;
        })
        (kanidmProvisionedGroups.${groupName}.members or [ ]))
    kanidmGroupNames;
  invalidKanidmPersonNames = lib.filter
    (name: !nameValidation.validKanidmUser name)
    kanidmPersonNames;
  invalidKanidmGroupNames = lib.filter
    (name: !nameValidation.validKanidmGroup name)
    kanidmGroupNames;
  invalidKanidmGroupMemberships = lib.filter
    (membership: !nameValidation.validKanidmEntryName membership.memberName)
    kanidmGroupMemberships;
  fileSystemHasOption = mountPoint: option:
    builtins.elem option (config.fileSystems.${mountPoint}.options or [ ]);
  fileAccessGids = lib.attrValues vars.fileAccessPosixGids;
  uniqueFileAccessGids = lib.unique fileAccessGids;
  invalidFileAccessGids = lib.filterAttrs
    (_: gid: !(builtins.isInt gid) || gid < 1000 || gid > 59999)
    vars.fileAccessPosixGids;
  fileAccessGroupNamesRaw = {
    webAccessGroup = vars.fileAccess.webAccessGroup or null;
    sftpAccessGroup = vars.fileAccess.sftpAccessGroup or null;
    sharedAccessGroup = vars.fileAccess.sharedAccessGroup or null;
    usbAccessGroup = vars.fileAccess.usbAccessGroup or null;
  };
  localSftpAccessGroupRaw = vars.fileAccess.localSftpAccessGroup or null;
  validLocalSftpAccessGroup =
    builtins.isString localSftpAccessGroupRaw
    && builtins.stringLength localSftpAccessGroupRaw >= 1
    && builtins.stringLength localSftpAccessGroupRaw <= 31
    && builtins.match "[a-z_][a-z0-9_-]*" localSftpAccessGroupRaw != null;
  invalidFileAccessGroupNameFields = builtins.attrNames (lib.filterAttrs
    (_: group: !nameValidation.validKanidmGroup group)
    fileAccessGroupNamesRaw);
  configuredFileAccessGroupNames = builtins.filter builtins.isString (lib.attrValues fileAccessGroupNamesRaw);
  managedFileAccessGroupNames = configuredFileAccessGroupNames ++ [
    vars.backupAdminGroup
    vars.backupStorageGroup
  ];
  duplicateManagedFileAccessGroupNames = lib.unique (lib.filter
    (group:
      builtins.length (builtins.filter (candidate: candidate == group) managedFileAccessGroupNames) > 1)
    managedFileAccessGroupNames);
  staticIdentityAndApplicationGroupNames = [
    "admin-backups"
    "app-admin"
    "audiobookshelf-users"
    "domain_admins"
    "downloads-users"
    "idm_account_policy_admins"
    "idm_group_admins"
    "idm_oauth2_admins"
    "idm_people_admins"
    "idm_people_on_boarding"
    "idm_people_pii_read"
    "idm_unix_admins"
    "immich-users"
    "jellyfin-users"
    "kavita-users"
    "kiwix-users"
    "mail-archive-users"
    "media-automation-users"
    "paperless-users"
    "system_admins"
    "user-files"
    "users"
  ];
  reservedIdentityAndApplicationGroupNames =
    staticIdentityAndApplicationGroupNames
    ++ [ vars.monitoringAccessGroup ]
    ++ lib.optionals seerrEnabled [ vars.seerrRequestManagerGroup ];
  reservedFileAccessGroupNames = reservedIdentityAndApplicationGroupNames ++ [
    localSftpAccessGroupRaw
  ];
  reservedFileAccessGroupNameCollisions = lib.intersectLists
    configuredFileAccessGroupNames
    reservedFileAccessGroupNames;
  backupAccessReservedGroupNames = lib.unique (
    configuredFileAccessGroupNames
    ++ [
      localSftpAccessGroupRaw
      config.repo.backups.maintenanceGroup
    ]
    ++ reservedIdentityAndApplicationGroupNames
  );
  backupAccessReservedGroupNameCollisions = lib.filterAttrs
    (_: group:
      builtins.isString group
      && builtins.elem group backupAccessReservedGroupNames)
    {
      adminGroup = backupAdminGroupRaw;
      storageGroup = backupStorageGroupRaw;
    };
  explicitLocalGroupNames = builtins.attrNames (lib.filterAttrs
    (_: group: (group.gid or null) != null)
    config.users.groups);
  localPrimaryGroupNames = builtins.filter builtins.isString (map
    (user: user.group or null)
    (lib.attrValues config.users.users));
  localSupplementaryGroupNames = lib.concatMap
    (user: builtins.filter builtins.isString (user.extraGroups or [ ]))
    (lib.attrValues config.users.users);
  localUserReferencedGroupNames = lib.unique (
    localPrimaryGroupNames
    ++ localSupplementaryGroupNames
  );
  # Rclone is deliberately a supplementary member of the backup storage
  # group. Ignore only that expected edge; primary-group use (including
  # rclone's own service group) and every other local-user reference still
  # prove that the configured name already has a different local purpose.
  localSupplementaryGroupNamesWithoutRcloneStorage = lib.concatLists (lib.mapAttrsToList
    (userName: user:
      builtins.filter
        (group:
          builtins.isString group
          && !(userName == "rclone" && group == vars.backupStorageGroup))
        (user.extraGroups or [ ]))
    config.users.users);
  localSftpReservedGroupNames = lib.unique (
    configuredFileAccessGroupNames
    ++ [
      vars.backupAdminGroup
      vars.backupStorageGroup
      config.repo.backups.maintenanceGroup
    ]
    ++ reservedIdentityAndApplicationGroupNames
    ++ explicitLocalGroupNames
    ++ localUserReferencedGroupNames
  );
  localSftpAccessGroupCollisions =
    if builtins.isString localSftpAccessGroupRaw
    then builtins.filter (group: group == localSftpAccessGroupRaw) localSftpReservedGroupNames
    else [ ];
  expectedFileAccessGidAssignments = [
    {
      field = "webAccessGroup";
      group = fileAccessGroupNamesRaw.webAccessGroup;
      gid = 2001;
    }
    {
      field = "sftpAccessGroup";
      group = fileAccessGroupNamesRaw.sftpAccessGroup;
      gid = 2002;
    }
    {
      field = "sharedAccessGroup";
      group = fileAccessGroupNamesRaw.sharedAccessGroup;
      gid = 2003;
    }
    {
      field = "usbAccessGroup";
      group = fileAccessGroupNamesRaw.usbAccessGroup;
      gid = 2004;
    }
  ];
  invalidFileAccessGidAssignments = map
    (assignment: assignment.field)
    (builtins.filter
      (assignment:
        !(builtins.isString assignment.group)
        || !(builtins.hasAttr assignment.group vars.fileAccessPosixGids)
        || vars.fileAccessPosixGids.${assignment.group} != assignment.gid)
      expectedFileAccessGidAssignments);
  # The SFTP bridge deliberately creates these local groups with the local
  # administrator as a group.members entry. That expected membership is not a
  # collision. A different resolved GID or use as any local user's primary or
  # supplementary group proves that the name already belongs to another local
  # service or system role.
  fileAccessLocalGroupNameCollisions = builtins.listToAttrs (map
    (assignment: {
      name = assignment.field;
      value = assignment.group;
    })
    (builtins.filter
      (assignment:
        builtins.isString assignment.group
        && (
          let
            localGroup = config.users.groups.${assignment.group} or { };
          in
          (
            (localGroup.gid or null) != null
            && localGroup.gid != assignment.gid
          )
          || builtins.elem assignment.group localUserReferencedGroupNames
        ))
      expectedFileAccessGidAssignments));
  fileAccessLocalGidCollisions = builtins.listToAttrs (builtins.filter
    (collision: collision.value != [ ])
    (map
      (assignment: {
        name = assignment.field;
        value = builtins.attrNames (lib.filterAttrs
          (name: group:
            (!builtins.isString assignment.group || name != assignment.group)
            && (group.gid or null) == assignment.gid)
          config.users.groups);
      })
      expectedFileAccessGidAssignments));
  backupStorageGidMappingValid =
    builtins.hasAttr vars.backupStorageGroup vars.fileAccessPosixGids
    && vars.fileAccessPosixGids.${vars.backupStorageGroup} == vars.backupStorageGid;
  backupStorageGidLocalGroupCollisions = builtins.attrNames (lib.filterAttrs
    (name: group:
      name != vars.backupStorageGroup
      && builtins.isInt backupStorageGidRaw
      && (group.gid or null) == backupStorageGidRaw)
    config.users.groups);
  backupStorageLocalGroupNameCollisions =
    if builtins.isString backupStorageGroupRaw then
      let
        localGroup = config.users.groups.${backupStorageGroupRaw} or { };
        hasUnexpectedExplicitGid =
          builtins.isInt backupStorageGidRaw
          && (localGroup.gid or null) != null
          && localGroup.gid != backupStorageGidRaw;
        referencedForAnotherLocalPurpose = builtins.elem backupStorageGroupRaw (
          localPrimaryGroupNames
          ++ localSupplementaryGroupNamesWithoutRcloneStorage
        );
      in
      lib.optional
        (hasUnexpectedExplicitGid || referencedForAnotherLocalPurpose)
        backupStorageGroupRaw
    else
      [ ];
  backupAdminProvision = config.services.kanidm.provision.groups.${vars.backupAdminGroup};
  backupStorageProvision = config.services.kanidm.provision.groups.${vars.backupStorageGroup};
  storageOnlyUsersInAdminGroup = lib.intersectLists
    vars.backupStorageUsers
    (backupAdminProvision.members or [ ]);
  backupAdminsMissingStorageGroup = lib.filter
    (user: !(builtins.elem user (backupStorageProvision.members or [ ])))
    vars.kanidmBackupAdminUsers;
  sharedMountName = vars.fileAccess.sharedMountName or "";
  filestashEnabled = config.services.filestash.enable or false;
  filestashPackageHasProxyPasswordAuth =
    !filestashEnabled
    || (config.services.filestash.package.proxyPasswordAuthPlugin or false);
  filestashIdentityProvider =
    config.services.filestash.settings.middleware.identity_provider.type or "";
  filestashBackendParams =
    builtins.fromJSON (config.services.filestash.settings.middleware.attribute_mapping.params or "{}");
  filestashBackendPaths =
    (map (backend: backend.path or "") (lib.attrValues filestashBackendParams))
    ++ (map (connection: connection.path or "") (config.services.filestash.settings.connections or [ ]));
  directFilestashSharedPaths =
    lib.filter
      (path: path == vars.sharedRoot || lib.hasPrefix "${vars.sharedRoot}/" path)
      filestashBackendPaths;
  sshdSettings = config.services.openssh.settings;
  normalSshAllowSftp = config.services.openssh.allowSFTP;
  normalSshAllowUsers = sshdSettings.AllowUsers or [ ];
  normalSshAuthorizedKeysCommand = sshdSettings.AuthorizedKeysCommand or null;
  filesSftpPam = config.security.pam.services.files-sftp-sshd;
  filesSftpKanidmAuthUsesFirstPass =
    filesSftpPam.rules.auth.kanidm.settings.use_first_pass or false;
  localAdminNeedsSftpBridge = builtins.elem vars.localAdminUser (vars.filesSftpUsers or [ ]);
  localBridgeFileAccessGroups = lib.filter
    (group: builtins.hasAttr group vars.fileAccessPosixGids)
    (lib.unique [
      (vars.fileAccess.webAccessGroup or "files-personal-users")
      (vars.fileAccess.sftpAccessGroup or "files-sftp-users")
      (vars.fileAccess.sharedAccessGroup or "files-shared-users")
      (vars.fileAccess.usbAccessGroup or "usb-access")
      vars.backupStorageGroup
    ]);
  localBridgeGroupsWithWrongGid = lib.filter
    (group: (config.users.groups.${group}.gid or null) != vars.fileAccessPosixGids.${group})
    localBridgeFileAccessGroups;
  localBridgeGroupsMissingLocalAdmin = lib.filter
    (group: !(builtins.elem vars.localAdminUser (config.users.groups.${group}.members or [ ])))
    localBridgeFileAccessGroups;
  persistenceDirectoryPath = entry:
    if builtins.isString entry then
      entry
    else
      entry.directory or entry.path or "";
  persistedPathsInsidePersist = lib.filter
    (path: path == "/persist" || lib.hasPrefix "/persist/" path)
    (map persistenceDirectoryPath config.repo.impermanence.inventory.persistenceDirectories);
  offlineMediaCfg = vars.offlineMedia;
  offlineMediaEnabled =
    (config.nixhomeserver.modules."offline-music" or false)
    && (offlineMediaCfg.enable or false);
  offlineMediaStateDir = offlineMediaCfg.stateDir or "/persist/appdata/offline-media";
  offlineMediaTmpfilesRule = "d ${offlineMediaStateDir} 0750 root root -";
  seerrEnabled =
    (config.nixhomeserver.modules.seerr or false)
    && (config.repo.seerr.enable or false);
  monitoringAccessGroupRaw = vars.monitoringAccess.group or null;
  seerrRequestManagerGroupRaw = vars.seerrAccess.requestManagerGroup or null;
  offlineMediaAccessGroupRaw = offlineMediaCfg.accessGroup or "users";
  activeOfflineMediaAccessGroups = lib.optional
    (
      offlineMediaEnabled
      && nameValidation.validKanidmGroup offlineMediaAccessGroupRaw
      && offlineMediaAccessGroupRaw != "users"
    )
    offlineMediaAccessGroupRaw;
  authorizationReservedGroupNames = lib.unique (builtins.filter builtins.isString (
    staticIdentityAndApplicationGroupNames
    ++ configuredFileAccessGroupNames
    ++ [
      vars.backupAdminGroup
      vars.backupStorageGroup
      localSftpAccessGroupRaw
      config.repo.backups.maintenanceGroup
    ]
    ++ activeOfflineMediaAccessGroups
  ));
  monitoringAccessGroupCollision =
    nameValidation.validKanidmGroup monitoringAccessGroupRaw
    && builtins.elem vars.monitoringAccessGroup authorizationReservedGroupNames;
  seerrRequestManagerGroupCollision =
    seerrEnabled
    && nameValidation.validKanidmGroup seerrRequestManagerGroupRaw
    && builtins.elem vars.seerrRequestManagerGroup authorizationReservedGroupNames;
  supportedHostPlatforms = [ "x86_64-linux" "aarch64-linux" ];
  supportedHardwareProfiles = [ "generated" "existing-server" "generic-uefi" ];
  supportedStorageProfiles = [ "zfs-mirror" "single-disk-ext4" ];
  safeDiskId = storageValidation.validDiskId;
  dataMirrorPairs = vars.zfsDataPool.mirrorPairs or [ ];
  validMirrorPairs = builtins.all
    (pair: builtins.isList pair && builtins.length pair == 2 && builtins.all safeDiskId pair)
    dataMirrorPairs;
  uniqueDataDiskIds = lib.unique vars.zfsDataPoolDiskIds;
  canonicalDataDatasets = [ "users" "shared" "backups" ];
  configuredDataDatasets = vars.zfsDataPool.datasets or [ ];
  canonicalDatasetSet =
    lib.sort builtins.lessThan configuredDataDatasets
    == lib.sort builtins.lessThan canonicalDataDatasets;
  validDataMountPoint = builtins.match "/mnt/[A-Za-z0-9][A-Za-z0-9._-]*" vars.dataRoot != null;
  validDataPoolName = storageValidation.validZpoolName vars.zfsDataPool.name;
  conflictingDataFileSystems = lib.filter
    (mountPoint: mountPoint == vars.dataRoot || lib.hasPrefix "${vars.dataRoot}/" mountPoint)
    (builtins.attrNames config.fileSystems);
  configuredKanidmGroups = kanidmGroupNames;
  protectedCanaryGroups = builtins.filter
    (group: builtins.elem group [ "app-admin" "domain_admins" "system_admins" ] || lib.hasPrefix "idm_" group)
    configuredKanidmGroups;
  canaryProtectedMemberships = builtins.filter
    (group: builtins.elem vars.kanidmCanaryUser (kanidmProvisionedGroups.${group}.members or [ ]))
    protectedCanaryGroups;
  canaryIdentityCollisionSources = identityValidation.canaryCollisionSources vars;
in
{
  assertions = identityUserListTypeAssertions ++ identityUserListMemberAssertions ++ [
    {
      assertion = identityAppUserEmailsAreAttrs;
      message = "nixhomeserver: identity.appUserEmails must be an attribute set mapping Kanidm usernames to email addresses, for example { alice = \"alice@example.org\"; }.";
    }
    {
      assertion = invalidIdentityAppUserEmailNames == [ ];
      message = "nixhomeserver: identity.appUserEmails keys must be canonical Kanidm usernames: ${builtins.toJSON invalidIdentityAppUserEmailNames}";
    }
    {
      assertion = invalidIdentityAppUserEmailValues == [ ];
      message = "nixhomeserver: identity.appUserEmails values must be ordinary user@public-domain email address strings; invalid usernames: ${builtins.toJSON invalidIdentityAppUserEmailValues}";
    }
    {
      assertion = identityAdminMailAddressesAreList;
      message = "nixhomeserver: identity.adminMailAddresses must be a list of email address strings, for example [ \"admin@example.org\" ]; do not use a bare string.";
    }
    {
      assertion = invalidIdentityAdminMailAddresses == [ ];
      message = "nixhomeserver: identity.adminMailAddresses entries must be ordinary user@public-domain email address strings.";
    }
    {
      assertion = !(builtins.hasAttr "offlineMusic" vars);
      message = "nixhomeserver: vars.offlineMusic was removed; use vars.offlineMedia.";
    }
    {
      assertion = builtins.elem vars.hostPlatform supportedHostPlatforms;
      message = "nixhomeserver: system.hostPlatform must be one of: ${lib.concatStringsSep ", " supportedHostPlatforms}.";
    }
    {
      assertion = builtins.elem vars.hardwareProfile supportedHardwareProfiles;
      message = "nixhomeserver: system.hardwareProfile must be one of: ${lib.concatStringsSep ", " supportedHardwareProfiles}.";
    }
    {
      assertion = vars.hardwareProfile != "existing-server" || vars.hostPlatform == "x86_64-linux";
      message = "nixhomeserver: system.hardwareProfile = existing-server is this repo's checked-in x86_64 hardware profile. Generate hardware-configuration.nix and use generated for aarch64-linux.";
    }
    {
      assertion = builtins.elem vars.storageProfile supportedStorageProfiles;
      message = "nixhomeserver: storage.profile must be one of: ${lib.concatStringsSep ", " supportedStorageProfiles}.";
    }
    {
      assertion = safeDiskId vars.mainDisk;
      message = "nixhomeserver: storage.systemDisk must be a safe /dev/disk/by-id basename, not a path or whitespace-containing value.";
    }
    {
      assertion = validDataMountPoint;
      message = "nixhomeserver: storage.dataPool.mountPoint must be a normalized /mnt/<name> path with no trailing slash or traversal components.";
    }
    {
      assertion = validDataPoolName;
      message = "nixhomeserver: storage.dataPool.name must be a non-empty ZFS-compatible pool name.";
    }
    {
      assertion = canonicalDatasetSet && builtins.length configuredDataDatasets == builtins.length canonicalDataDatasets;
      message = "nixhomeserver: storage.dataPool.datasets must contain exactly users, shared, and backups once each.";
    }
    {
      assertion = !vars.enableZfsDataPool || (dataMirrorPairs != [ ] && validMirrorPairs);
      message = "nixhomeserver: zfs-mirror requires one or more data mirror pairs containing exactly two safe by-id basenames each.";
    }
    {
      assertion =
        !vars.enableZfsDataPool
          || (
          builtins.length uniqueDataDiskIds == builtins.length vars.zfsDataPoolDiskIds
            && !(builtins.elem vars.mainDisk vars.zfsDataPoolDiskIds)
        );
      message = "nixhomeserver: system and ZFS data disks must be distinct, and each configured data-disk ID may appear only once.";
    }
    {
      assertion =
        vars.brandName != ""
          && builtins.stringLength vars.brandName <= 100
          && !lib.hasInfix "\n" vars.brandName
          && !lib.hasInfix "\r" vars.brandName;
      message = "nixhomeserver: branding.displayName must be 1-100 characters on one line.";
    }
    {
      assertion = allowPlaceholders || vars.domain != "example.test";
      message = "nixhomeserver: replace the example domain before using this host for install/deploy.";
    }
    {
      assertion = allowPlaceholders || !containsChangeMe vars.serverSSHPubKey;
      message = "nixhomeserver: replace serverSSHPubKey with a real SSH public key.";
    }
    {
      assertion = allowPlaceholders || !containsChangeMe vars.netIface;
      message = "nixhomeserver: replace the LAN interface placeholder.";
    }
    {
      assertion = allowPlaceholders || !containsChangeMe vars.mainDisk;
      message = "nixhomeserver: replace mainDisk with a /dev/disk/by-id basename.";
    }
    {
      assertion = allowPlaceholders || !vars.enableZfsDataPool || !(lib.any containsChangeMe vars.zfsDataPoolDiskIds);
      message = "nixhomeserver: replace all ZFS data-pool disk placeholders.";
    }
    {
      assertion = allowPlaceholders || !vars.enableZfsDataPool || vars.hostId != "00000000";
      message = "nixhomeserver: replace the example hostId with a stable 8-character hexadecimal value for ZFS.";
    }
    {
      assertion = validHostId;
      message = "nixhomeserver: system.hostId must be exactly 8 lowercase hexadecimal characters.";
    }
    {
      assertion = vars.kanidmAdminUser != vars.localAdminUser;
      message = "nixhomeserver: identity.adminUser must be a dedicated Kanidm operator account, not the local Unix admin '${vars.localAdminUser}'.";
    }
    {
      assertion = nameValidation.validDnsLabel vars.hostname;
      message = "nixhomeserver: network.hostname must be a lowercase DNS label of at most 63 characters.";
    }
    {
      assertion = nameValidation.validPublicDomain vars.domain;
      message = "nixhomeserver: network.domain must be a valid lowercase public DNS name.";
    }
    {
      assertion = nameValidation.validDnsName vars.networking.dns.lanDomain;
      message = "nixhomeserver: dnsSettings.lanDomain must be a valid lowercase DNS name.";
    }
    {
      assertion = builtins.elem vars.networking.dns.privacyMode supportedDnsPrivacyModes;
      message = "nixhomeserver: dnsSettings.privacyMode must be one of: ${lib.concatStringsSep ", " supportedDnsPrivacyModes}.";
    }
    {
      assertion = lanDnsHostsAreAttrs;
      message = "nixhomeserver: dnsSettings.lanHosts must be an attribute set mapping DNS names to IPv4 addresses.";
    }
    {
      assertion = invalidLanDnsHostNames == [ ];
      message = "nixhomeserver: dnsSettings.lanHosts names must be valid lowercase bare or fully qualified DNS names (an optional trailing dot is allowed): ${builtins.toJSON invalidLanDnsHostNames}";
    }
    {
      assertion = invalidLanDnsHostAddressNames == [ ];
      message = "nixhomeserver: dnsSettings.lanHosts values must be valid IPv4 addresses; invalid host entries: ${builtins.toJSON invalidLanDnsHostAddressNames}";
    }
    {
      assertion = offLanDnsHostAddressNames == [ ];
      message = "nixhomeserver: dnsSettings.lanHosts addresses must be usable host addresses in the configured network.lanIp/network.lanPrefixLength subnet; invalid host entries: ${builtins.toJSON offLanDnsHostAddressNames}";
    }
    {
      assertion = invalidKanidmPersonNames == [ ];
      message = "nixhomeserver: provisioned Kanidm person names must start with a lowercase letter, contain only lowercase letters, digits, dot, underscore, or hyphen, and be at most 64 characters: ${builtins.toJSON invalidKanidmPersonNames}";
    }
    {
      assertion = invalidKanidmGroupNames == [ ];
      message = "nixhomeserver: provisioned Kanidm group names must start with a lowercase letter, contain only lowercase letters, digits, dot, underscore, or hyphen, and be at most 64 characters: ${builtins.toJSON invalidKanidmGroupNames}";
    }
    {
      assertion = invalidKanidmGroupMemberships == [ ];
      message = "nixhomeserver: provisioned Kanidm group members must use valid local Kanidm entry names: ${builtins.toJSON invalidKanidmGroupMemberships}";
    }
    {
      assertion = nameValidation.validKanidmGroup monitoringAccessGroupRaw;
      message = "nixhomeserver: monitoringAccess.group must be a valid Kanidm group name.";
    }
    {
      assertion = nameValidation.validKanidmGroup seerrRequestManagerGroupRaw;
      message = "nixhomeserver: seerrAccess.requestManagerGroup must be a valid Kanidm group name.";
    }
    {
      assertion = !seerrEnabled || vars.monitoringAccessGroup != vars.seerrRequestManagerGroup;
      message = "nixhomeserver: monitoringAccess.group and seerrAccess.requestManagerGroup must be distinct when Seerr is enabled.";
    }
    {
      assertion = !monitoringAccessGroupCollision;
      message = "nixhomeserver: monitoringAccess.group must be a dedicated authorization group and must not reuse a core, delegated, application, file-access, backup, active offline-media, local bridge, or maintenance group: ${builtins.toJSON monitoringAccessGroupRaw}";
    }
    {
      assertion = !seerrRequestManagerGroupCollision;
      message = "nixhomeserver: seerrAccess.requestManagerGroup must be a dedicated authorization group when Seerr is enabled and must not reuse a core, delegated, application, file-access, backup, active offline-media, local bridge, or maintenance group: ${builtins.toJSON seerrRequestManagerGroupRaw}";
    }
    {
      assertion = canaryIdentityCollisionSources == [ ] && canaryProtectedMemberships == [ ];
      message = "nixhomeserver: identity.canaryUser must be distinct from configured human identities and remain non-privileged; identity collisions: ${lib.concatStringsSep ", " canaryIdentityCollisionSources}; protected memberships: ${lib.concatStringsSep ", " canaryProtectedMemberships}";
    }
    {
      assertion = kanidmAdminAppUserMailConflicts == [ ];
      message = "nixhomeserver: identity.adminMailAddresses must not reuse an address assigned in identity.appUserEmails: ${lib.concatStringsSep ", " kanidmAdminAppUserMailConflicts}";
    }
    {
      assertion = invalidMailAddresses == [ ];
      message = "nixhomeserver: identity admin and app-user mail addresses must be ordinary user@public-domain addresses: ${lib.concatStringsSep ", " invalidMailAddresses}";
    }
    {
      assertion = allowPlaceholders || placeholderMailAddresses == [ ];
      message = "nixhomeserver: replace example, .test, and CHANGE_ME identity email placeholders before install/deploy: ${lib.concatStringsSep ", " placeholderMailAddresses}";
    }
    {
      assertion = builtins.elem vars.dnsMode [ "split-horizon" "netbird-only" ];
      message = "nixhomeserver: dnsMode must be either split-horizon or netbird-only.";
    }
    {
      assertion = networkValidation.validIPv4 vars.serverLanIP;
      message = "nixhomeserver: network.lanIp must be a valid IPv4 address.";
    }
    {
      assertion = networkValidation.validIPv4 vars.networking.lan.gateway;
      message = "nixhomeserver: network.lanGateway must be a valid IPv4 address.";
    }
    {
      assertion =
        builtins.isInt vars.networking.lan.prefixLength
          && vars.networking.lan.prefixLength >= 1
          && vars.networking.lan.prefixLength <= 30;
      message = "nixhomeserver: network.lanPrefixLength must be an integer between 1 and 30.";
    }
    {
      assertion = networkValidation.sameUsableSubnet vars.serverLanIP vars.networking.lan.gateway vars.networking.lan.prefixLength;
      message = "nixhomeserver: network.lanIp and network.lanGateway must be usable addresses in the same configured subnet.";
    }
    {
      assertion = networkValidation.validIPv4 vars.networking.netbird.ip;
      message = "nixhomeserver: network.netbirdIp must be a valid IPv4 address.";
    }
    {
      assertion = networkValidation.validIPv4Cidr vars.networking.netbird.cidr;
      message = "nixhomeserver: network.netbirdCidr must be a valid IPv4 CIDR.";
    }
    {
      assertion = networkValidation.cidrContains vars.networking.netbird.ip vars.networking.netbird.cidr;
      message = "nixhomeserver: network.netbirdIp must belong to network.netbirdCidr.";
    }
    {
      assertion = builtins.length portValues == builtins.length uniquePortValues;
      message = "nixhomeserver: configured and derived service endpoints contain duplicate port values (including the Kopia authentication bridge at networking.ports.kopia + 1).";
    }
    {
      assertion = invalidEndpointPorts == { };
      message = "nixhomeserver: configured and derived service endpoint ports must be integers from 1 through 65535: ${builtins.toJSON invalidEndpointPorts}";
    }
    {
      assertion = invalidHostNames == [ ];
      message = "nixhomeserver: host names must be bare hostnames without scheme, path, or port: ${lib.concatStringsSep ", " invalidHostNames}";
    }
    {
      assertion = offDomainAppHosts == [ ];
      message = "nixhomeserver: app Caddy hosts must live under ${vars.domain}: ${lib.concatStringsSep ", " offDomainAppHosts}";
    }
    {
      assertion = cloudflareWithoutCaddy == [ ];
      message = "nixhomeserver: Cloudflare ingress entries need matching Caddy virtual hosts: ${lib.concatStringsSep ", " cloudflareWithoutCaddy}";
    }
    {
      assertion = invalidDnsHosts == [ ];
      message = "nixhomeserver: private DNS hosts must publish on LAN, NetBird, or both: ${lib.concatStringsSep ", " invalidDnsHosts}";
    }
    {
      assertion = insecureOauth2Urls == [ ];
      message = "nixhomeserver: OAuth2 URLs must use https or an explicitly allowed native app redirect unless allowInsecureUrls is set: ${lib.concatStringsSep "; " insecureOauth2Urls}";
    }
    {
      assertion =
        vars.storageProfile != "zfs-mirror"
          ||
          fileSystemHasOption "/" "subvol=/"
          || fileSystemHasOption "/" "subvol=${config.repo.impermanence.rootSubvolume}";
      message = "nixhomeserver: root Btrfs mount must retain its subvol option in the initrd.";
    }
    {
      assertion = vars.storageProfile != "zfs-mirror" || fileSystemHasOption "/nix" "subvol=/nix";
      message = "nixhomeserver: /nix Btrfs mount must retain subvol=/nix in the initrd.";
    }
    {
      assertion = vars.storageProfile != "zfs-mirror" || fileSystemHasOption "/persist" "subvol=/persist";
      message = "nixhomeserver: /persist Btrfs mount must retain subvol=/persist in the initrd.";
    }
    {
      assertion = vars.storageProfile != "single-disk-ext4" || (config.fileSystems."/".fsType or null) == "ext4";
      message = "nixhomeserver: single-disk-ext4 requires the root filesystem to be ext4.";
    }
    {
      assertion = vars.storageProfile != "single-disk-ext4" || !(builtins.hasAttr "/nix" config.fileSystems);
      message = "nixhomeserver: single-disk-ext4 expects /nix to be a regular directory on the root filesystem, not a separate mount.";
    }
    {
      assertion = vars.storageProfile != "single-disk-ext4" || !(builtins.hasAttr "/persist" config.fileSystems);
      message = "nixhomeserver: single-disk-ext4 expects /persist to be a regular directory on the root filesystem, not a separate mount.";
    }
    {
      assertion = conflictingDataFileSystems == [ ];
      message = "nixhomeserver: hardware-configuration.nix must not declare data-pool filesystems; regenerate it with --no-filesystems. Conflicts: ${lib.concatStringsSep ", " conflictingDataFileSystems}";
    }
    {
      assertion = persistedPathsInsidePersist == [ ];
      message = "nixhomeserver: repo.impermanence.directories must not include /persist paths because environment.persistence.\"/persist\" would remap them under /persist/persist: ${lib.concatStringsSep ", " persistedPathsInsidePersist}";
    }
    {
      assertion =
        !offlineMediaEnabled
          || (
          lib.hasPrefix "/persist/appdata/" offlineMediaStateDir
            && offlineMediaStateDir != "/persist/persist"
            && !(lib.hasPrefix "/persist/persist/" offlineMediaStateDir)
        );
      message = "nixhomeserver: offline media Syncthing enrollment state must live directly under /persist/appdata, not nested under /persist/persist: ${offlineMediaStateDir}";
    }
    {
      assertion =
        !offlineMediaEnabled
          || builtins.elem offlineMediaTmpfilesRule config.systemd.tmpfiles.rules;
      message = "nixhomeserver: offline media Syncthing enrollment state directory must be created directly by tmpfiles: ${offlineMediaTmpfilesRule}";
    }
    {
      assertion = builtins.length fileAccessGids == builtins.length uniqueFileAccessGids;
      message = "nixhomeserver: vars.fileAccessPosixGids contains duplicate GID values.";
    }
    {
      assertion = invalidFileAccessGids == { };
      message = "nixhomeserver: file-access POSIX GIDs must be integers from 1000 through 59999: ${builtins.toJSON invalidFileAccessGids}";
    }
    {
      assertion = invalidFileAccessGroupNameFields == [ ];
      message = "nixhomeserver: fileAccess webAccessGroup, sftpAccessGroup, sharedAccessGroup, and usbAccessGroup must be valid Kanidm group names; invalid fields: ${builtins.toJSON invalidFileAccessGroupNameFields}";
    }
    {
      assertion = validLocalSftpAccessGroup;
      message = "nixhomeserver: fileAccess.localSftpAccessGroup must be a lowercase local Unix group name of at most 31 characters (start with a letter or underscore; then letters, digits, underscore, or hyphen).";
    }
    {
      assertion = localSftpAccessGroupCollisions == [ ];
      message = "nixhomeserver: fileAccess.localSftpAccessGroup must be a dedicated local bridge group and must not reuse a file-access, backup, identity, application, maintenance, built-in, or service group: ${builtins.toJSON localSftpAccessGroupCollisions}";
    }
    {
      assertion = invalidFileAccessGidAssignments == [ ];
      message = "nixhomeserver: configurable file-access groups must retain stable POSIX GIDs (web=2001, SFTP=2002, shared=2003, USB=2004); invalid fields: ${builtins.toJSON invalidFileAccessGidAssignments}";
    }
    {
      assertion = fileAccessLocalGroupNameCollisions == { };
      message = "nixhomeserver: fileAccess groups must not reuse local built-in or service group names; colliding fields: ${builtins.toJSON fileAccessLocalGroupNameCollisions}";
    }
    {
      assertion = fileAccessLocalGidCollisions == { };
      message = "nixhomeserver: fileAccess POSIX GIDs 2001 through 2004 must not reuse explicit local system or service group GIDs; colliding fields and groups: ${builtins.toJSON fileAccessLocalGidCollisions}";
    }
    {
      assertion = reservedFileAccessGroupNameCollisions == [ ];
      message = "nixhomeserver: fileAccess group names must not reuse local bridge, retired, core identity, or application group names: ${builtins.toJSON reservedFileAccessGroupNameCollisions}";
    }
    {
      assertion = nameValidation.validKanidmGroup backupAdminGroupRaw;
      message = "nixhomeserver: backupAccess.adminGroup must be a valid Kanidm group name.";
    }
    {
      assertion = nameValidation.validKanidmGroup backupStorageGroupRaw;
      message = "nixhomeserver: backupAccess.storageGroup must be a valid Kanidm group name.";
    }
    {
      assertion = backupAdminGroupRaw != backupStorageGroupRaw;
      message = "nixhomeserver: backupAccess.adminGroup and backupAccess.storageGroup must be distinct security groups.";
    }
    {
      assertion = backupAccessReservedGroupNameCollisions == { };
      message = "nixhomeserver: backupAccess adminGroup and storageGroup must not reuse file-access, local bridge, maintenance, core identity, or application group names: ${builtins.toJSON backupAccessReservedGroupNameCollisions}";
    }
    {
      assertion = backupStorageLocalGroupNameCollisions == [ ];
      message = "nixhomeserver: backupAccess.storageGroup must not reuse a local built-in or service group: ${builtins.toJSON backupStorageLocalGroupNameCollisions}";
    }
    {
      assertion =
        builtins.isInt backupStorageGidRaw
          && backupStorageGidRaw >= 1000
          && backupStorageGidRaw <= 59999;
      message = "nixhomeserver: backupAccess.storageGid must be an integer from 1000 through 59999.";
    }
    {
      assertion = backupStorageGidMappingValid;
      message = "nixhomeserver: backupAccess.storageGroup must map deterministically to backupAccess.storageGid in vars.fileAccessPosixGids.";
    }
    {
      assertion = backupStorageGidLocalGroupCollisions == [ ];
      message = "nixhomeserver: backupAccess.storageGid must not reuse an explicit local system or service group GID; colliding groups: ${builtins.toJSON backupStorageGidLocalGroupCollisions}";
    }
    {
      assertion = duplicateManagedFileAccessGroupNames == [ ];
      message = "nixhomeserver: backup admin/storage and file-access group names must all be distinct; duplicates: ${builtins.toJSON duplicateManagedFileAccessGroupNames}";
    }
    {
      assertion = validBackupAdminUsers;
      message = "nixhomeserver: backupAccess.adminUsers must be a list of valid Kanidm user names.";
    }
    {
      assertion = validBackupStorageUsers;
      message = "nixhomeserver: backupAccess.storageUsers must be a list of valid Kanidm user names.";
    }
    {
      assertion = overlappingBackupAccessUsers == [ ];
      message = "nixhomeserver: backupAccess.adminUsers and backupAccess.storageUsers must not overlap; admins inherit storage membership automatically.";
    }
    {
      assertion =
        (backupAdminProvision.overwriteMembers or false)
          && (backupStorageProvision.overwriteMembers or false)
          && storageOnlyUsersInAdminGroup == [ ]
          && backupAdminsMissingStorageGroup == [ ];
      message = "nixhomeserver: backup groups must reconcile exactly, exclude storage-only users from administration, and grant storage membership to every backup admin.";
    }
    {
      assertion = sharedMountName != "" && !(lib.hasInfix "/" sharedMountName);
      message = "nixhomeserver: vars.fileAccess.sharedMountName must be a non-empty path name, not a path.";
    }
    {
      assertion = lib.hasPrefix "_" sharedMountName;
      message = "nixhomeserver: vars.fileAccess.sharedMountName should start with '_' so the shared view sorts first and reads as special.";
    }
    {
      assertion = filestashPackageHasProxyPasswordAuth;
      message = "nixhomeserver: Filestash must be built with the proxy-password authentication plugin.";
    }
    {
      assertion = !filestashEnabled || filestashIdentityProvider == "proxy_password";
      message = "nixhomeserver: Filestash must use the proxy_password identity provider.";
    }
    {
      assertion = !filestashEnabled || vars.filesSessionExpirationHours <= 12;
      message = "nixhomeserver: filesSessionExpirationHours must stay short because the encrypted Filestash cookie contains the managed SFTP credential.";
    }
    {
      assertion = directFilestashSharedPaths == [ ];
      message = "nixhomeserver: Filestash must not expose vars.sharedRoot directly; use the per-user protected shared mount instead.";
    }
    {
      assertion = normalSshAllowUsers == [ vars.localAdminUser ];
      message = "nixhomeserver: normal SSH must be limited to the local admin user; Kanidm file users use the dedicated SFTP endpoint only.";
    }
    {
      assertion = !normalSshAllowSftp;
      message = "nixhomeserver: normal SSH must not expose SFTP; file transfers use the dedicated chrooted files SFTP endpoint on vars.networking.ports.filesSftp.";
    }
    {
      assertion = filesSftpPam.unixAuth == localAdminNeedsSftpBridge;
      message = "nixhomeserver: files-sftp-sshd unixAuth must be enabled only when the local admin is also a files SFTP user; that local bridge is required because /etc/passwd resolves the bare admin username before Kanidm.";
    }
    {
      assertion = !localAdminNeedsSftpBridge || localBridgeGroupsWithWrongGid == [ ];
      message = "nixhomeserver: local files SFTP bridge groups must use vars.fileAccessPosixGids: ${lib.concatStringsSep ", " localBridgeGroupsWithWrongGid}";
    }
    {
      assertion = !localAdminNeedsSftpBridge || localBridgeGroupsMissingLocalAdmin == [ ];
      message = "nixhomeserver: local files SFTP bridge user '${vars.localAdminUser}' must be a local member of these file-access groups: ${lib.concatStringsSep ", " localBridgeGroupsMissingLocalAdmin}";
    }
    {
      assertion = !filesSftpKanidmAuthUsesFirstPass;
      message = "nixhomeserver: files-sftp-sshd Kanidm PAM auth must prompt directly instead of using use_first_pass, because Unix auth is disabled for this service.";
    }
    {
      assertion = normalSshAuthorizedKeysCommand == null;
      message = "nixhomeserver: normal SSH must not use Kanidm AuthorizedKeysCommand; per-user Kanidm SSH keys are not part of the file-access flow.";
    }
  ];
}
