{ lib, ... }:

rec {
  # ---------------------------------------------------------------------------
  # Start here: these sections are the normal operator-facing settings.
  # Most admins should be able to configure a new server by editing only this
  # first block, then running `nix run .#validate-config-readiness`.
  # ---------------------------------------------------------------------------

  identity = {
    adminUser = "kanidm-admin"; # Dedicated Kanidm operator account; keep separate from the local Unix admin.
    appUsers = [ ]; # Extra existing Kanidm users granted default access to hosted apps.
    appAdminUsers = [ ]; # Extra existing Kanidm users granted app-level admin roles.
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
    timeZone = "Etc/UTC"; # IANA time zone for timers, logs, and local maintenance windows.
    hostId = "00000000"; # Replace with a stable 8-character hexadecimal host ID for real deployments.
  };

  dnsSettings = {
    mode = "split-horizon"; # Either "split-horizon" or "netbird-only".
    privacyMode = "encrypted-only"; # Keep recursive upstream DNS on encrypted transports only.
    lanDomain = "home.arpa";
    lanHosts = {
      "${network.hostname}" = network.lanIp;
      router = network.lanGateway;
    };
  };

  edge = {
    cloudflareTunnelName = "CHANGE_ME_TUNNEL"; # Cloudflare Tunnel name from `cloudflared tunnel list`.
  };

  storage = {
    systemDisk = "CHANGE_ME_SYSTEM_DISK_BY_ID"; # System SSD /dev/disk/by-id basename.
    dataPool = {
      name = "data";
      mountPoint = "/mnt/data";
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
    webAccessGroup = "user-files"; # Browser file access and personal files root provisioning.
    sftpAccessGroup = "files-sftp-users"; # Restricted SFTP login access.
    localSftpAccessGroup = "files-local-sftp-users"; # Local Unix bridge group allowed for SFTP shadow password sync.
    sharedAccessGroup = "files-shared-users"; # Adds the protected _Shared view inside personal roots.
    usbAccessGroup = "usb-access"; # Adds the _USB view inside personal roots when external USB media is manually mounted.
    sharedMountName = "_Shared";
    usbMountName = "_USB";
    sftpChrootBase = "/srv/files-sftp/chroots";
  };

  backupAccess = {
    adminGroup = "backup-admins"; # Grants access to the Kopia backup-management UI.
    adminUsers = [ ]; # Extra existing Kanidm users allowed to manage backups.
    storageGroup = "admin-backups"; # Grants read access to encrypted backup repository files.
    storageUsers = [ ]; # Extra existing Kanidm users allowed to browse backup repository files.
    storageMountName = "_Backups";
  };

  phoneBackup = {
    enable = false; # Set true after replacing the Syncthing device ID below.
    maxRepositoryBytes = 75 * 1024 * 1024 * 1024;
    minimumSuccessfulSnapshots = 7;
    compression = "zstd";
    repositoryPath = "${backupRoot}/kopia-phone";
    stateDir = "/persist/appdata/kopia-phone";
    syncthing = {
      deviceName = "phone";
      deviceId = "REPLACE_WITH_SYNCTHING_FORK_DEVICE_ID";
      folderId = "nixhomeserver-kopia-phone";
    };
    sources = {
      includePersist = true;
      extraPaths = [ ];
      excludePatterns = [
        "**/.cache/**"
        "**/cache/**"
        "**/tmp/**"
        "**/thumbs/**"
        "**/encoded-video/**"
      ];
    };
  };

  advanced = rec {
    # Advanced networking values are rarely changed on first install.
    loopbackIPv4 = "127.0.0.1";
    loopbackIPv6 = "::1";
    loopbackIPv4Cidr = "127.0.0.0/8";
    loopbackProxyCidr = "127.0.0.1/32";
    ports = {
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
      kopia = 51515;
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
  timeZone = system.timeZone;
  hostId = system.hostId;
  kanidmAdminUser = identity.adminUser;
  kanidmAppUsers = lib.unique ([ identity.adminUser ] ++ (identity.appUsers or [ ]));
  kanidmAppAdminUsers = lib.unique ([ identity.adminUser ] ++ (identity.appAdminUsers or [ ]));
  kanidmBackupAdminUsers = lib.unique ([ identity.adminUser ] ++ (backupAccess.adminUsers or [ ]));
  kanidmBackupStorageUsers = lib.unique ([ identity.adminUser ] ++ (backupAccess.storageUsers or (backupAccess.adminUsers or [ ])));
  kanidmAppUserEmails = identity.appUserEmails or { };
  kanidmAdminMailAddresses = identity.adminMailAddresses or [ ];
  kanidmAdminEmail = identity.adminEmail;
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

  mainDisk = storage.systemDisk;
  zfsDataPool = storage.dataPool;

  cloudflareTunnelName = edge.cloudflareTunnelName;
  binaryCaches = advanced.binaryCaches;

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs; # Bootstrap-era pool member IDs retained for blank-machine provisioning metadata.

  dataRoot = zfsDataPool.mountPoint;
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
  backupRoot = "${dataRoot}/backups";
  externalUsbMountRoot = "/mnt/external-usb";
  staleReferenceCleanup = {
    users = false;
    shared = false;
  };
  uploadSecurity = {
    stagingRoot = "${dataRoot}/upload-staging";
    quarantineRoot = "${dataRoot}/quarantine/uploads";
  };
  fileAccessPosixGids = {
    "user-files" = 2001;
    "files-sftp-users" = 2002;
    "files-shared-users" = 2003;
    "usb-access" = 2004;
    "admin-backups" = 2005;
  };
  filesSftpUsers = kanidmAppUsers; # Kanidm users with POSIX accounts and restricted files SFTP chroots.
  jellyfinAdminUsers = kanidmAppAdminUsers;
  userContentSubdirs = [ ];
  sharedContentSubdirs = [ ];

  kanidmDomain = "id.${domain}";
  kopiaDomain = "backups.${domain}";
  kanidmBaseUrl = "https://${kanidmDomain}";
  kanidmIssuer = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}";
  kanidmDiscoveryUrl = clientId: "${kanidmIssuer clientId}/.well-known/openid-configuration";
}
