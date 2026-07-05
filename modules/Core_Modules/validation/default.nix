{ config, lib, vars, ... }:

let
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
        || (lib.hasInfix "://" name && !isAllowedLanAlias)
        || (lib.hasInfix "/" name && !isAllowedLanAlias)
        || (lib.hasInfix ":" name && !isAllowedLanAlias))
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
  legacyOfflineMusicCfg = vars.offlineMusic or { };
  offlineMediaCfg =
    if builtins.hasAttr "offlineMedia" vars then vars.offlineMedia else legacyOfflineMusicCfg;
  offlineMediaEnabled = offlineMediaCfg.enable or false;
  offlineMediaStateDir = offlineMediaCfg.stateDir or "/persist/appdata/offline-media";
  offlineMediaTmpfilesRule = "d ${offlineMediaStateDir} 0750 root root -";
  supportedHostPlatforms = [ "x86_64-linux" "aarch64-linux" ];
  supportedHardwareProfiles = [ "existing-server" "generic-uefi" ];
  supportedStorageProfiles = [ "zfs-mirror" "single-disk-ext4" ];
in
{
  assertions = [
    {
      assertion = builtins.elem vars.hostPlatform supportedHostPlatforms;
      message = "nixhomeserver: system.hostPlatform must be one of: ${lib.concatStringsSep ", " supportedHostPlatforms}.";
    }
    {
      assertion = builtins.elem vars.hardwareProfile supportedHardwareProfiles;
      message = "nixhomeserver: system.hardwareProfile must be one of: ${lib.concatStringsSep ", " supportedHardwareProfiles}.";
    }
    {
      assertion = builtins.elem vars.storageProfile supportedStorageProfiles;
      message = "nixhomeserver: storage.profile must be one of: ${lib.concatStringsSep ", " supportedStorageProfiles}.";
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
      assertion = allowPlaceholders || vars.hostId != "00000000";
      message = "nixhomeserver: replace the example hostId with a stable 8-character hexadecimal value.";
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
      assertion = kanidmAdminAppUserMailConflicts == [ ];
      message = "nixhomeserver: identity.adminMailAddresses must not reuse an address assigned in identity.appUserEmails: ${lib.concatStringsSep ", " kanidmAdminAppUserMailConflicts}";
    }
    {
      assertion = builtins.elem vars.dnsMode [ "split-horizon" "netbird-only" ];
      message = "nixhomeserver: dnsMode must be either split-horizon or netbird-only.";
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
