{ lib, ... }:

rec {
  # ---------------------------------------------------------------------------
  # Start here: these sections are the normal operator-facing settings.
  # Most admins should be able to configure a new server by editing only this
  # first block, then running `nix run .#validate-config-readiness`.
  # ---------------------------------------------------------------------------

  identity = {
    adminUser = "admin"; # Delegated Kanidm operator account.
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
      ];
    };
  };

  power = {
    enable = true;
    cpuGovernor = "powersave";
    suspendCalendar = "*-*-* 04:30:00"; # Suspend after normal overnight maintenance timers have started.
    wakeTime = "06:00";
    skipIfSshSessions = true;
    skipIfOtherUserSessions = true;
    blockerUnits = [
      "zfs-scrub.service"
      "btrfs-scrub--.service"
      "restic-backups-system-state.service"
      "storage-smart-long.service"
      "storage-smart-short.service"
    ];
    wakeOnLan = {
      enable = true;
      interface = network.lanInterface;
      policy = [ "magic" ];
    };
    powertopAutoTune = false; # Broad auto-tuning can be too aggressive for a storage server.
    scsiLinkPolicy = null; # Keep the kernel default for SATA/SCSI link power management.
    usbAutoSuspend = {
      enable = false;
      denyList = [ ];
    };
    fstrimCalendar = "Sun *-*-* 19:00:00";
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
      oauth2ProxyUploads = 4180;
      oauth2ProxyMailArchive = 4181;
      oauth2ProxyKiwix = 4182;
      oauth2ProxyDownloads = 4183;
      oauth2ProxyFilestash = 4184;
      paperless = 8000;
      audiobookshelf = 13378;
      copyparty = 3923;
      filestash = 8334;
      mailArchiveUi = 9011;
      immich = 2283;
      immichPublicProxy = 3300;
      immichPublicProxyContainer = 3000;
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

  resourceLimits = {
    immichMachineLearning = {
      memoryMax = "6G";
      cpuQuota = "250%";
    };
    clamav.memoryMax = "3G";
    restic = {
      cpuQuota = "150%";
      ioWeight = 100;
    };
    youtubeDownloader.cpuQuota = "200%";
    mediaIndexers.cpuQuota = "150%";
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
  powerManagement = power;
  kanidmAuthSessionExpirySeconds = 259200; # Kanidm auth session lifetime in seconds.
  kanidmPrivilegeSessionExpirySeconds = 900; # Kanidm privileged write window in seconds.
  uploadsOauth2ProxyCookieExpire = "720h0m0s"; # Copyparty OAuth2 Proxy browser session lifetime.
  filesSessionExpirationHours = 720; # Files web UI browser session lifetime in hours.

  mainDisk = storage.systemDisk;
  zfsDataPool = storage.dataPool;

  cloudflareTunnelName = edge.cloudflareTunnelName;
  binaryCaches = advanced.binaryCaches;

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs; # Bootstrap-era pool member IDs retained for blank-machine provisioning metadata.

  dataRoot = zfsDataPool.mountPoint;
  paperlessRoot = "${dataRoot}/paperless";
  paperlessInboxRoot = "${paperlessRoot}/inbox";
  paperlessHandoffStagingRoot = "${paperlessRoot}/handoff-staging";
  paperlessArchiveRoot = "${paperlessRoot}/archive";
  paperlessExportRoot = "${paperlessRoot}/export";
  immichRoot = "${dataRoot}/immich";
  immichManagedRoot = "${immichRoot}/managed";
  immichExternalRoot = "${immichRoot}/external";
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
  staleReferenceCleanup = {
    users = false;
    shared = false;
  };
  uploadSecurity = {
    stagingRoot = "${dataRoot}/upload-staging";
    quarantineRoot = "${dataRoot}/quarantine/uploads";
    adminReviewGroup = "app-admin";
    zimPromotionGroup = "app-admin";
    scanSettleSeconds = 30;
    rescanInterval = "5m";
    clamavTimeoutSeconds = 300;
    virusTotalTimeoutSeconds = 20;
    virusTotalMaliciousThreshold = 1;
    virusTotalSuspiciousThreshold = 1;
    lowRiskExtensions = [
      "pdf"
      "docx"
      "xlsx"
      "pptx"
      "jpg"
      "jpeg"
      "png"
      "gif"
      "webp"
      "mp3"
      "flac"
      "m4a"
      "opus"
      "wav"
      "mp4"
      "mkv"
      "webm"
    ];
    highRiskExtensions = [
      "exe"
      "dll"
      "scr"
      "com"
      "msi"
      "bat"
      "cmd"
      "ps1"
      "psm1"
      "vbs"
      "js"
      "jse"
      "hta"
      "jar"
      "apk"
      "deb"
      "rpm"
      "appimage"
      "iso"
      "img"
      "dmg"
      "zip"
      "7z"
      "rar"
      "tar"
      "gz"
      "bz2"
      "xz"
      "doc"
      "docm"
      "dotm"
      "xls"
      "xlsm"
      "xltm"
      "xlsb"
      "xlam"
      "ppt"
      "pptm"
      "potm"
      "pps"
      "ppsm"
      "html"
      "svg"
      "rtf"
      "zim"
    ];
  };
  fileAccessPosixGids = {
    "user-files" = 2001;
  };
  personalKavitaLibraries = [
    {
      dir = "ebooks";
      type = 2;
      fileGroupTypes = [ 2 3 1 ];
      label = "Ebooks";
    }
    {
      dir = "comics";
      type = 1;
      fileGroupTypes = [ 1 4 3 ];
      label = "Comics";
    }
    {
      dir = "manga";
      type = 0;
      fileGroupTypes = [ 1 4 ];
      label = "Manga";
    }
  ];
  jellyfinVideoLibraries = [
    {
      dir = "movies";
      collectionType = "movies";
      label = "Movies";
    }
    {
      dir = "shows";
      collectionType = "tvshows";
      label = "Shows";
    }
    {
      dir = "home";
      collectionType = "homevideos";
      label = "Home Videos";
    }
    {
      dir = "music-videos";
      collectionType = "musicvideos";
      label = "Music Videos";
    }
    {
      dir = "youtube";
      collectionType = "homevideos";
      label = "YouTube";
    }
  ];
  jellyfinAdminUsers = [ kanidmAdminUser ];
  personalJellyfinLibraries = jellyfinVideoLibraries;
  sharedJellyfinLibraries = jellyfinVideoLibraries;
  sharedKavitaLibraries = personalKavitaLibraries;
  userBooksSubdirs = map (library: library.dir) personalKavitaLibraries;
  userVideoSubdirs = map (library: library.dir) personalJellyfinLibraries;
  sharedBooksSubdirs = map (library: library.dir) sharedKavitaLibraries;
  sharedVideoSubdirs = map (library: library.dir) sharedJellyfinLibraries;
  sharedJellyfinMusicLibraries = [ ];
  sharedMusicSubdirs = map (library: library.dir) sharedJellyfinMusicLibraries;
  sharedAudiobooksRoot = "${sharedRoot}/audiobooks";
  sharedBooksRoot = "${sharedRoot}/books";
  sharedEbooksRoot = "${sharedBooksRoot}/ebooks";
  sharedComicsRoot = "${sharedBooksRoot}/comics";
  sharedMangaRoot = "${sharedBooksRoot}/manga";
  sharedEmailsRoot = "${sharedRoot}/emails";
  sharedMusicRoot = "${sharedRoot}/music";
  sharedYouTubeMusicRoot = "${sharedMusicRoot}/youtube";
  sharedVideosRoot = "${sharedRoot}/videos";
  sharedMoviesRoot = "${sharedVideosRoot}/movies";
  sharedShowsRoot = "${sharedVideosRoot}/shows";
  sharedHomeVideosRoot = "${sharedVideosRoot}/home";
  sharedMusicVideosRoot = "${sharedVideosRoot}/music-videos";
  sharedYouTubeRoot = "${sharedVideosRoot}/youtube";
  sharedOtherVideosRoot = "${sharedVideosRoot}/other";
  userContentSubdirs = [
    "audiobooks"
    "books"
    "emails"
    "files"
    "videos"
  ];
  sharedContentSubdirs = [
    "audiobooks"
    "books"
    "emails"
    "kiwix"
    "videos"
    "files"
  ];

  kanidmDomain = "id.${domain}";
  kanidmBaseUrl = "https://${kanidmDomain}";
  kanidmIssuer = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}";
  kanidmDiscoveryUrl = clientId: "${kanidmIssuer clientId}/.well-known/openid-configuration";
  immichPublicProxyPort = networking.ports.immichPublicProxy;
  filesPort = networking.ports.filestash;
  filesStateDir = "/var/lib/filestash";
  kiwixLibraryRoot = "${dataRoot}/kiwix";
}
