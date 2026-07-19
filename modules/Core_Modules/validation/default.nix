{ config, lib, vars, ... }:

let
  networkValidation = import ../../../lib/network-validation.nix { inherit lib; };
  identityValidation = import ../../../lib/identity-validation.nix;
  nameValidation = import ../../../lib/name-validation.nix { inherit lib; };
  storageValidation = import ../../../lib/storage-validation.nix { inherit lib; };
  allowPlaceholders = vars.validation.allowPlaceholders or false;
  containsChangeMe = value: lib.hasInfix "CHANGE_ME" (toString value);
  externallyBoundPorts = lib.filterAttrs (name: _: !(lib.hasSuffix "Container" name)) vars.networking.ports;
  portValues = lib.attrValues externallyBoundPorts;
  uniquePortValues = lib.unique portValues;
  caddyHosts = builtins.attrNames config.services.caddy.virtualHosts;
  cloudflareHosts = builtins.attrNames config.services.cloudflared.tunnels.${vars.cloudflareTunnelName}.ingress;
  privateDnsHosts = config.services.unbound.privateHosts;
  privateDnsHostNames = builtins.attrNames privateDnsHosts;
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
      (vars.backupAccess.storageGroup or "backup-admin")
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
  assertions = [
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
      assertion = canaryIdentityCollisionSources == [ ] && canaryProtectedMemberships == [ ];
      message = "nixhomeserver: identity.canaryUser must be distinct from configured human identities and remain non-privileged; identity collisions: ${lib.concatStringsSep ", " canaryIdentityCollisionSources}; protected memberships: ${lib.concatStringsSep ", " canaryProtectedMemberships}";
    }
    {
      assertion = kanidmAdminAppUserMailConflicts == [ ];
      message = "nixhomeserver: identity.adminMailAddresses must not reuse an address assigned in identity.appUserEmails: ${lib.concatStringsSep ", " kanidmAdminAppUserMailConflicts}";
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
      assertion = vars.networking.lan.prefixLength >= 1 && vars.networking.lan.prefixLength <= 30;
      message = "nixhomeserver: network.lanPrefixLength must be between 1 and 30.";
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
      message = "nixhomeserver: vars.networking.ports contains duplicate port values.";
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
