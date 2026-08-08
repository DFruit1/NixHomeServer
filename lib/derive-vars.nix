{ lib, settings }:

let
  inherit (settings)
    branding
    edge
    network
    system
    ;
  configuredIdentity = settings.identity;
  configuredApplications = settings.applications;
  identity = configuredIdentity // {
    canaryUser = "canary-user";
    adminMailAddresses = [ configuredIdentity.adminEmail ];
  };
  configuredDnsSettings = settings.dnsSettings;
  dnsSettings = configuredDnsSettings // {
    privacyMode = "encrypted-only";
    lanDomain = "internal";
    lanHosts = {
      "${network.hostname}" = network.lanIp;
      router = network.lanGateway;
    };
  };
  configuredStorage = settings.storage;
  configuredDataPool = configuredStorage.dataPool or { };
  storage = configuredStorage // {
    dataPool = {
      name = "data";
      mountPoint = "/mnt/data";
      expectedGuid = configuredDataPool.expectedGuid or null;
      mirrorPairs = configuredDataPool.mirrorPairs or [ ];
      datasets = [
        "users"
        "shared"
        "backups"
      ];
    };
  };
  fileAccess = {
    webAccessGroup = "files-personal-users";
    sftpAccessGroup = "files-sftp-users";
    localSftpAccessGroup = "files-local-sftp-users";
    sharedAccessGroup = "files-shared-users";
    deleteSharedAccessGroup = "delete_shared_files";
    usbAccessGroup = "usb-access";
    sharedMountName = "_Shared";
    usbMountName = "_USB";
    sftpChrootBase = "/srv/files-sftp/chroots";
  };
  backupAccess = {
    adminGroup = "backup-admin";
    storageGroup = "backup-storage-users";
    storageGid = 2005;
    storageMountName = "_Backups";
  };
  monitoringAccess = {
    group = "monitoring-users";
    users = [
      identity.adminUser
      identity.canaryUser
    ];
  };
  seerrAccess = {
    requestManagerGroup = "seerr-request-managers";
  };
  configuredOfflineMedia = settings.offlineMedia or { };
  offlineMedia = {
    enable = configuredOfflineMedia.enable or true;
    musicFolderName = "_Music";
    stateDir = "/persist/appdata/offline-media";
    musicFolderIdPrefix = "nixhomeserver-music";
    youtubeFolderIdPrefix = "nixhomeserver-youtube-videos";
    otherFolderIdPrefix = "nixhomeserver-other-videos";
    accessGroup = "users";
  };
  ports = {
    http = 80;
    https = 443;
    dns = 53;
    dnscryptProxy = 5053;
    netbirdWireGuard = 51820;
    kanidm = 8443;
    oauth2ProxyMailArchive = 4181;
    oauth2ProxyKiwix = 4182;
    oauth2ProxyDownloads = 4183;
    oauth2ProxyFilestash = 4184;
    oauth2ProxyKopia = 4185;
    oauth2ProxyHomepage = 4186;
    oauth2ProxyMonitor = 4187;
    beszelHub = 8090;
    beszelAgent = 45876;
    kopia = 51515;
    groundwaterLogger = 8091;
    groundwaterMqtt = 1883;
    homepage = 8084;
    bonsai = 8086;
    mediaManager = 8087;
    paperless = 8000;
    audiobookshelf = 13378;
    filestash = 8334;
    filesSftp = 2222;
    mailArchiveUi = 9011;
    immich = 2283;
    immichPublicProxy = 3300;
    kiwix = 8081;
    kavita = 5000;
    vaultwarden = 8222;
    jellyfin = 8096;
    jellyfinDiscovery = 7359;
    youtubeDownloader = 8083;
    seerr = 5055;
    sonarr = 8989;
    radarr = 7878;
    prowlarr = 9696;
    qbittorrentWeb = 8085;
    qbittorrentTorrent = 51413;
    oauth2ProxySeerr = 4189;
    oauth2ProxySonarr = 4190;
    oauth2ProxyRadarr = 4191;
    oauth2ProxyProwlarr = 4192;
    oauth2ProxyQbittorrent = 4193;
  };
  advanced = {
    loopbackIPv4 = "127.0.0.1";
    loopbackIPv6 = "::1";
    loopbackIPv4Cidr = "127.0.0.0/8";
    loopbackProxyCidr = "127.0.0.1/32";
    inherit ports;
    dnsBootstrapResolvers = [
      {
        address = "9.9.9.9";
        port = ports.dns;
      }
      {
        address = "1.1.1.1";
        port = ports.dns;
      }
    ];
  };
  configuredOffsiteBackup = settings.offsiteBackup or { };
in
rec {
  inherit
    backupAccess
    dnsSettings
    fileAccess
    identity
    monitoringAccess
    offlineMedia
    seerrAccess
    storage
    ;
  hostname = network.hostname;
  applications = configuredApplications;
  enabledApps = configuredApplications.enabled;
  domain = network.domain;
  hostPlatform = system.hostPlatform or "x86_64-linux";
  hardwareProfile = system.hardwareProfile;
  timeZone = system.timeZone;
  hostId = system.hostId;
  buildMode = system.buildMode or "remote";
  nixStoreMaxSizeGiB = system.nixStoreMaxSizeGiB or 80;
  nixGcRetentionDays = system.nixGcRetentionDays or 45;
  localNixGCMode = system.localNixGCMode or (
    if system.localNixGC or false then
      "always"
    else
      "never"
  );
  # Retain the normalized boolean for older internal consumers while new code
  # selects the explicit policy above.
  localNixGC = localNixGCMode != "never";
  buildSlots = {
    local =
      if buildMode == "local" || buildMode == "maximum-effort" then "auto"
      else if buildMode == "balanced" then 2
      else 0;
    remote =
      if buildMode == "remote" || buildMode == "maximum-effort" then "auto"
      else if buildMode == "balanced" then 2
      else 0;
  };
  buildCores = {
    # NIX_BUILD_CORES is advisory. Cooperative builders stay near two busy
    # cores per host in balanced mode, while other modes retain all-core jobs.
    local = if buildMode == "balanced" then 1 else 0;
    remote = if buildMode == "balanced" then 1 else 0;
  };
  kanidmAdminUser = identity.adminUser;
  kanidmCanaryUser = identity.canaryUser;
  authorizationGroupModel = (import ./authorization-groups.nix { inherit lib; }) {
    inherit monitoringAccess seerrAccess;
  };
  configuredMonitoringAccessGroup = authorizationGroupModel.configuredMonitoringGroup;
  monitoringAccessGroup = authorizationGroupModel.monitoringGroup;
  configuredSeerrRequestManagerGroup = authorizationGroupModel.configuredSeerrRequestManagerGroup;
  identityAccessModel = (import ./identity-access.nix { inherit lib; }) {
    inherit identity monitoringAccess;
  };
  configuredIdentityAppUsers = identityAccessModel.configuredAppUsers;
  configuredIdentityAppAdminUsers = identityAccessModel.configuredAppAdminUsers;
  configuredIdentityAppUserEmails = identityAccessModel.configuredAppUserEmails;
  configuredIdentityAdminMailAddresses = identityAccessModel.configuredAdminMailAddresses;
  configuredMonitoringAccessUsers = identityAccessModel.configuredMonitoringUsers;
  kanidmAppUsers = identityAccessModel.appUsers;
  kanidmAppAdminUsers = identityAccessModel.appAdminUsers;
  monitoringAccessUsers = identityAccessModel.monitoringUsers;
  fileAccessGidModel = import ./file-access-gids.nix { inherit fileAccess; };
  backupAccessModel = import ./backup-access.nix {
    inherit backupAccess;
    basePosixGids = fileAccessGidModel.posixGids;
  };
  backupAdminGroup = backupAccessModel.adminGroup;
  backupStorageGroup = backupAccessModel.storageGroup;
  backupStorageGid = backupAccessModel.storageGid;
  kanidmAppUserEmails = identityAccessModel.appUserEmails // {
    ${identity.canaryUser} = "${identity.canaryUser}@${network.domain}";
  };
  kanidmAdminMailAddresses = identityAccessModel.adminMailAddresses;
  kanidmAdminEmail = identity.adminEmail;
  seerrRequestManagerGroup = authorizationGroupModel.seerrRequestManagerGroup;
  serverSSHPubKey = identity.sshPublicKey;
  localAdminUser = identity.localAdminUser;

  networking = rec {
    loopbackIPv4 = advanced.loopbackIPv4;
    loopbackIPv6 = advanced.loopbackIPv6;
    loopbackIPv4Cidr = advanced.loopbackIPv4Cidr;
    loopbackProxyCidr = advanced.loopbackProxyCidr;
    interfaces = {
      lan = network.lanInterface;
      netbird = "nb0";
    };
    lan = {
      ip = network.lanIp;
      prefixLength = network.lanPrefixLength;
      gateway = network.lanGateway;
    };
    netbird = {
      ip = network.netbirdIp;
      cidr = network.netbirdCidr;
    };
    dns = {
      mode = dnsSettings.mode;
      privacyMode = dnsSettings.privacyMode;
      lanDomain = dnsSettings.lanDomain;
      lanHosts = dnsSettings.lanHosts;
      bootstrapResolvers = advanced.dnsBootstrapResolvers;
    };
    ports = advanced.ports;
    dnsBootstrapResolvers = dns.bootstrapResolvers;
  };

  serverLanIP = networking.lan.ip;
  serverLanPrefixLength = networking.lan.prefixLength;
  serverLanGateway = networking.lan.gateway;
  nbIP = networking.netbird.ip;
  dnsMode = networking.dns.mode;
  dnsPrivacyMode = networking.dns.privacyMode;
  lanDnsDomain = networking.dns.lanDomain;
  lanDnsHosts = networking.dns.lanHosts;
  netIface = networking.interfaces.lan;
  kanidmAuthSessionExpirySeconds = 259200; # Kanidm auth session lifetime in seconds.
  kanidmPrivilegeSessionExpirySeconds = 900; # Kanidm privileged write window in seconds.
  filesSessionExpirationHours = 8; # Files web UI browser session lifetime in hours.
  brandName = branding.displayName;

  storageProfile = storage.profile or "zfs-mirror";
  enableRootRollback = storage.enableRootRollback or false;
  enableZfsDataPool = storageProfile == "zfs-mirror";
  dataRootIsMountPoint = enableZfsDataPool;
  mainDisk = storage.systemDisk;
  zfsDataPool = storage.dataPool or {
    name = "data";
    mountPoint = "/mnt/data";
    mirrorPairs = [ ];
    datasets = [
      "users"
      "shared"
      "backups"
    ];
  };

  cloudflareTunnelName = edge.cloudflareTunnelName;
  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs; # Bootstrap-era pool member IDs retained for blank-machine provisioning metadata.

  dataRoot = zfsDataPool.mountPoint;
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
  backupRoot = "${dataRoot}/backups";
  rcloneMega = {
    enable = configuredOffsiteBackup.enable or false;
    remoteName = "mega";
    email = configuredOffsiteBackup.email or "";
    sourcePath = "${backupRoot}/kopia";
    destination = "mega:NixHomeServer/kopia";
    syncOnCalendar = configuredOffsiteBackup.syncOnCalendar or "*-*-* 04,16:30:00";
    randomizedDelaySec = "30m";
    transfers = 4;
    checkers = 8;
    warnPercent = 80;
    criticalPercent = 90;
    repositoryLimitBytes = configuredOffsiteBackup.repositoryLimitBytes or (19 * 1024 * 1024 * 1024);
  };
  externalUsbMountRoot = "/mnt/external-usb";
  externalUsbViewMount = "/mnt/usb-access-view";
  staleReferenceCleanup = settings.staleReferenceCleanup;
  fileAccessPosixGids = backupAccessModel.fileAccessPosixGids;
  filesSftpUsers = kanidmAppUsers; # Kanidm users with POSIX accounts and restricted files SFTP chroots.
  jellyfinAdminUsers = kanidmAppAdminUsers;
  userContentSubdirs = [ ];
  sharedContentSubdirs = [ ];

  kanidmDomain = "id.${domain}";
  kopiaDomain = "kopia.${domain}";
  monitorDomain = "monitor.${domain}";
  kanidmBaseUrl = "https://${kanidmDomain}";
  kanidmIssuer = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}";
  kanidmDiscoveryUrl = clientId: "${kanidmIssuer clientId}/.well-known/openid-configuration";
}
