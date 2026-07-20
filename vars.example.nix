{ lib, ... }:

rec {
  # ---------------------------------------------------------------------------
  # Start here: these sections are the normal operator-facing settings.
  # Most admins should be able to configure a new server by editing only this
  # first block, then running `nix run .#validate-config-readiness`.
  # ---------------------------------------------------------------------------

  branding = {
    displayName = "Home Server"; # Human-readable name shown in the portal and identity provider.
  };

  identity = {
    adminUser = "kanidm-admin"; # Dedicated Kanidm operator account; keep separate from the local Unix admin.
    canaryUser = "canary-user"; # Non-privileged synthetic user used by browser access checks.
    appUsers = [ ]; # Extra existing Kanidm users granted default access to hosted apps.
    appAdminUsers = [ ]; # Extra app admins; they inherit normal app access and need not be repeated in appUsers.
    appUserEmails = { }; # Optional email map for extra app users, for example { alice = "alice@example.test"; }.
    adminMailAddresses = [ ]; # Optional Kanidm mail addresses for the primary admin user.
    adminEmail = "admin@example.test"; # Contact email for ACME and the first Kanidm admin user.
    sshPublicKey = "ssh-ed25519 CHANGE_ME example-admin-key";
    localAdminUser = "admin"; # Local Unix SSH/sudo account for bootstrap and operations.
  };

  network = {
    hostname = "example-server"; # NixOS hostname and flake hostname alias.
    domain = "example.test"; # Public DNS zone used for app hostnames.
    lanInterface = "eth0"; # Target server's wired LAN interface.
    lanIp = "192.0.2.10"; # Static LAN address for the server.
    lanPrefixLength = 24;
    lanGateway = "192.0.2.1";
    netbirdIp = "100.64.0.10";
    netbirdCidr = "100.64.0.0/10";
  };

  system = {
    hostPlatform = "x86_64-linux"; # Nix target platform. Supported values: "x86_64-linux" and "aarch64-linux".
    hardwareProfile = "generated"; # Use the hardware-configuration.nix generated on the target. "generic-uefi" is an expert fallback only.
    timeZone = "Etc/UTC"; # IANA time zone for timers, logs, and local maintenance windows.
    hostId = "00000000"; # Replace with a stable 8-character hexadecimal host ID for zfs-mirror.
  };

  dnsSettings = {
    mode = "split-horizon"; # Either "split-horizon" or "netbird-only".
    privacyMode = "encrypted-only"; # Keep recursive upstream DNS on encrypted transports only.
    lanDomain = "internal";
    lanHosts = {
      "${network.hostname}" = network.lanIp;
      router = network.lanGateway;
    };
  };

  edge = {
    cloudflareTunnelName = "CHANGE_ME_TUNNEL"; # Cloudflare Tunnel name from `cloudflared tunnel list`.
  };

  storage = {
    profile = "zfs-mirror"; # Use "single-disk-ext4" for a simple one-disk install.
    enableRootRollback = false; # Optional for blank installs only; requires zfs-mirror and must be chosen before running Disko.
    systemDisk = "CHANGE_ME_SYSTEM_DISK_BY_ID"; # System SSD /dev/disk/by-id basename.
    dataPool = {
      name = "data";
      mountPoint = "/mnt/data";
      # Optional immutable ZFS identity. The first verified topology-only boot
      # logs the numeric GUID to place here; once set, a same-named foreign pool
      # is rejected even if device paths have changed.
      expectedGuid = null;
      mirrorPairs = [
        [
          "CHANGE_ME_DATA_DISK_1_BY_ID"
          "CHANGE_ME_DATA_DISK_2_BY_ID"
        ]
      ];
      datasets = [
        "users"
        "shared"
        "backups"
      ];
    };
  };

  fileAccess = {
    webAccessGroup = "files-personal-users"; # Browser file access and personal files root provisioning.
    sftpAccessGroup = "files-sftp-users"; # Restricted SFTP login access.
    localSftpAccessGroup = "files-local-sftp-users"; # Local Unix bridge group allowed for SFTP shadow password sync.
    sharedAccessGroup = "files-shared-users"; # Adds the protected _Shared view inside personal roots.
    usbAccessGroup = "usb-access"; # Adds the _USB view inside personal roots when external USB media is manually mounted.
    usbUsers = [ ]; # Kanidm users allowed to see _USB inside their personal file root.
    sharedMountName = "_Shared"; # Safe single directory name; no slashes, whitespace, or traversal components.
    usbMountName = "_USB"; # Safe single directory name shown in each permitted user root.
    sftpChrootBase = "/srv/files-sftp/chroots"; # Normalized absolute path below /srv; do not use /, .., or spaces.
  };

  backupAccess = {
    adminGroup = "backup-admin"; # Grants access to the Kopia backup-management UI.
    adminUsers = [ ]; # Extra existing Kanidm users allowed to manage backups.
    storageGroup = "backup-storage-users"; # Separate POSIX group granting read-only access to encrypted backup repository files.
    storageGid = 2005; # Stable on-disk GID for backup ownership and ACLs; keep unique and within 1000-59999.
    storageUsers = [ ]; # Storage-only users. Backup admins inherit storage access and should not be repeated here.
    storageMountName = "_Backups"; # Safe single directory name for the read-only repository view.
  };

  monitoringAccess = {
    group = "monitoring-users"; # Grants monitoring access without app-admin privileges.
    users = [ identity.adminUser identity.canaryUser ];
  };

  seerrAccess = {
    requestManagerGroup = "seerr-request-managers"; # Grants Seerr request approval and rejection permissions.
    requestManagers = [ identity.adminUser ];
  };

  offlineMedia = {
    enable = true;
    musicFolderName = "_Music"; # Safe relative directory name under each managed user root.
    stateDir = "/persist/appdata/offline-media";
    musicFolderIdPrefix = "nixhomeserver-music";
    youtubeFolderIdPrefix = "nixhomeserver-youtube-videos";
    otherFolderIdPrefix = "nixhomeserver-other-videos";
    accessGroup = "users";
  };

  advanced = rec {
    # Advanced networking values are rarely changed on first install.
    loopbackIPv4 = "127.0.0.1";
    loopbackIPv6 = "::1";
    loopbackIPv4Cidr = "127.0.0.0/8";
    loopbackProxyCidr = "127.0.0.1/32";
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
    binaryCaches = [ ]; # Optional extra binary caches: [{ url = "https://example.cachix.org"; publicKey = "example.cachix.org-1:..."; }]
  };

  # ---------------------------------------------------------------------------
  # Compatibility and derived values. Modules consume these names today.
  # New admins usually should not edit below this line directly.
  # ---------------------------------------------------------------------------

  hostname = network.hostname;
  domain = network.domain;
  hostPlatform = system.hostPlatform or "x86_64-linux";
  hardwareProfile = system.hardwareProfile or "generated";
  timeZone = system.timeZone;
  hostId = system.hostId;
  kanidmAdminUser = identity.adminUser;
  kanidmCanaryUser = identity.canaryUser;
  authorizationGroupModel = (import ./lib/authorization-groups.nix { inherit lib; }) {
    inherit monitoringAccess seerrAccess;
  };
  configuredMonitoringAccessGroup = authorizationGroupModel.configuredMonitoringGroup;
  monitoringAccessGroup = authorizationGroupModel.monitoringGroup;
  configuredSeerrRequestManagerGroup = authorizationGroupModel.configuredSeerrRequestManagerGroup;
  identityAccessModel = (import ./lib/identity-access.nix { inherit lib; }) {
    inherit fileAccess identity monitoringAccess seerrAccess;
  };
  configuredIdentityAppUsers = identityAccessModel.configuredAppUsers;
  configuredIdentityAppAdminUsers = identityAccessModel.configuredAppAdminUsers;
  configuredIdentityAppUserEmails = identityAccessModel.configuredAppUserEmails;
  configuredIdentityAdminMailAddresses = identityAccessModel.configuredAdminMailAddresses;
  configuredMonitoringAccessUsers = identityAccessModel.configuredMonitoringUsers;
  configuredSeerrRequestManagers = identityAccessModel.configuredSeerrRequestManagers;
  configuredFileAccessUsbUsers = identityAccessModel.configuredUsbUsers;
  kanidmAppUsers = identityAccessModel.appUsers;
  kanidmAppAdminUsers = identityAccessModel.appAdminUsers;
  monitoringAccessUsers = identityAccessModel.monitoringUsers;
  fileAccessUsbUsers = identityAccessModel.usbUsers;
  fileAccessGidModel = import ./lib/file-access-gids.nix { inherit fileAccess; };
  backupAccessModel = (import ./lib/backup-access.nix { inherit lib; }) {
    inherit backupAccess identity;
    basePosixGids = fileAccessGidModel.posixGids;
  };
  configuredBackupAdminUsers = backupAccessModel.configuredAdminUsers;
  configuredBackupStorageUsers = backupAccessModel.configuredStorageUsers;
  backupAdminUsers = backupAccessModel.adminUsers;
  backupStorageUsers = backupAccessModel.storageUsers;
  backupAdminGroup = backupAccessModel.adminGroup;
  backupStorageGroup = backupAccessModel.storageGroup;
  backupStorageGid = backupAccessModel.storageGid;
  kanidmBackupAdminUsers = backupAccessModel.adminMembers;
  kanidmBackupStorageUsers = backupAccessModel.storageMembers;
  kanidmBackupUsers = backupAccessModel.allUsers;
  kanidmAppUserEmails = identityAccessModel.appUserEmails // {
    ${identity.canaryUser} = "${identity.canaryUser}@${network.domain}";
  };
  kanidmAdminMailAddresses = identityAccessModel.adminMailAddresses;
  kanidmAdminEmail = identity.adminEmail;
  seerrRequestManagerGroup = authorizationGroupModel.seerrRequestManagerGroup;
  seerrRequestManagers = identityAccessModel.seerrRequestManagers;
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
  binaryCaches = advanced.binaryCaches;

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs; # Bootstrap-era pool member IDs retained for blank-machine provisioning metadata.

  dataRoot = zfsDataPool.mountPoint;
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
  backupRoot = "${dataRoot}/backups";
  rcloneMega = {
    enable = false;
    remoteName = "mega";
    email = "REPLACE_WITH_MEGA_EMAIL";
    sourcePath = "${backupRoot}/kopia";
    destination = "mega:NixHomeServer/kopia";
    syncOnCalendar = "*-*-* 04:30:00";
    randomizedDelaySec = "30m";
    transfers = 4;
    checkers = 8;
    warnPercent = 80;
    criticalPercent = 90;
    repositoryLimitBytes = 19327352832; # 18 GiB, preserving 2 GiB of MEGA headroom.
  };
  externalUsbMountRoot = "/mnt/external-usb";
  staleReferenceCleanup = {
    users = false;
    shared = false;
  };
  fileAccessPosixGids = backupAccessModel.fileAccessPosixGids;
  filesSftpUsers = kanidmAppUsers; # Kanidm users with POSIX accounts and restricted files SFTP chroots.
  jellyfinAdminUsers = kanidmAppAdminUsers;
  userContentSubdirs = [ ];
  sharedContentSubdirs = [ ];

  kanidmDomain = "id.${domain}";
  kopiaDomain = "backups.${domain}";
  monitorDomain = "monitor.${domain}";
  kanidmBaseUrl = "https://${kanidmDomain}";
  kanidmIssuer = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}";
  kanidmDiscoveryUrl = clientId: "${kanidmIssuer clientId}/.well-known/openid-configuration";
}
