{ lib, ... }:

rec {
  # ---------------------------------------------------------------------------
  # Start here: these sections are the normal operator-facing settings.
  # Most admins should be able to configure a new server by editing only this
  # first block, then running `nix run .#doctor`.
  # ---------------------------------------------------------------------------

  identity = {
    adminUser = "admindsaw"; # Delegated Kanidm operator account.
    adminEmail = "dsaw@tuta.io"; # Contact email for ACME and the first Kanidm admin user.
    sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server";
  };

  network = {
    hostname = "server"; # NixOS hostname and flake hostname alias.
    domain = "sydneybasiniot.org"; # Public DNS zone used for app hostnames.
    lanInterface = "enp34s0"; # Target server's wired LAN interface.
    lanIp = "192.168.8.12"; # Static LAN address for the server.
    lanPrefixLength = 24;
    lanGateway = "192.168.8.1";
    netbirdIp = "100.72.113.237";
    netbirdCidr = "100.64.0.0/10";
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
    cloudflareTunnelName = "metro"; # Cloudflare Tunnel name from `cloudflared tunnel list`.
  };

  storage = {
    systemDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"; # System SSD /dev/disk/by-id basename.
    dataPool = {
      name = "data";
      mountPoint = "/mnt/data";
      mirrorPairs = [
        [
          "ata-ST8000VN002-2ZM188_WPV3997N"
          "ata-ST8000VN002-2ZM188_WPV37712"
        ]
      ];
      datasets = [
        "users"
        "shared"
      ];
    };
  };

  apps = {
    files = {
      enable = true;
      subdomain = "files";
    };
    uploads = {
      enable = true;
      subdomain = "uploads";
    };
    photos = {
      enable = true;
      privateSubdomain = "photos";
      publicShareSubdomain = "sharephotos";
    };
    documents = {
      enable = true;
      subdomain = "paperless";
      ocrLanguage = "eng";
      allowDangerousMacroOfficeParsing = false;
    };
    audiobooks = {
      enable = true;
      subdomain = "audiobooks";
    };
    books = {
      enable = true;
      subdomain = "books";
    };
    videos = {
      enable = true;
      subdomain = "videos";
    };
    wiki = {
      enable = true;
      subdomain = "wiki";
    };
    downloads = {
      enable = true;
      subdomain = "ytdownload";
    };
    monitoring = {
      enable = true;
      subdomain = "monitor";
    };
    passwords = {
      enable = true;
      subdomain = "passwords";
    };
    mail = {
      enable = true;
      subdomain = "emails";
    };
  };

  enabledApps =
    lib.attrNames
      (lib.filterAttrs (_: app: app.enable or false) apps);

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
      oauth2ProxyMetube = 4183;
      oauth2ProxyGlances = 4184;
      paperless = 8000;
      audiobookshelf = 13378;
      copyparty = 3923;
      filebrowserQuantum = 8097;
      mailArchiveUi = 9011;
      immich = 2283;
      immichPublicProxy = 3300;
      immichPublicProxyContainer = 3000;
      kiwix = 8081;
      kavita = 5000;
      vaultwarden = 8222;
      jellyfin = 8096;
      jellyfinDiscovery = 7359;
      metube = 8083;
      metubeContainer = 8081;
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
  paperlessEnableDangerousMacroOfficeParsing = apps.documents.allowDangerousMacroOfficeParsing;
  paperlessOcrLanguage = apps.documents.ocrLanguage;
  kanidmAdminUser = identity.adminUser;
  kanidmAdminEmail = identity.adminEmail;
  serverSSHPubKey = identity.sshPublicKey;

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
  filebrowserTokenExpirationHours = 720; # FileBrowser Quantum web UI token lifetime in hours.

  mainDisk = storage.systemDisk;
  zfsDataPool = storage.dataPool;

  cloudflareTunnelName = edge.cloudflareTunnelName;
  binaryCaches = advanced.binaryCaches;

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs; # Bootstrap-era pool member IDs retained for blank-machine provisioning metadata.

  dataRoot = zfsDataPool.mountPoint;
  paperlessRoot = "${dataRoot}/paperless";
  paperlessInboxRoot = "${paperlessRoot}/inbox";
  paperlessArchiveRoot = "${paperlessRoot}/archive";
  paperlessExportRoot = "${paperlessRoot}/export";
  immichRoot = "${dataRoot}/immich";
  immichManagedRoot = "${immichRoot}/managed";
  immichExternalRoot = "${immichRoot}/external";
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
  fileAccessPosixGids = {
    "user-files" = 2001;
    "shared-files-read-write-access" = 2002;
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
  personalJellyfinLibraries = [ ];
  sharedJellyfinLibraries = [
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
    {
      dir = "other";
      collectionType = "homevideos";
      label = "Other Videos";
    }
  ];
  sharedKavitaLibraries = personalKavitaLibraries;
  userBooksSubdirs = map (library: library.dir) personalKavitaLibraries;
  userVideoSubdirs = map (library: library.dir) personalJellyfinLibraries;
  sharedBooksSubdirs = map (library: library.dir) sharedKavitaLibraries;
  sharedVideoSubdirs = map (library: library.dir) sharedJellyfinLibraries;
  sharedAudiobooksRoot = "${sharedRoot}/audiobooks";
  sharedBooksRoot = "${sharedRoot}/books";
  sharedEbooksRoot = "${sharedBooksRoot}/ebooks";
  sharedComicsRoot = "${sharedBooksRoot}/comics";
  sharedMangaRoot = "${sharedBooksRoot}/manga";
  sharedEmailsRoot = "${sharedRoot}/emails";
  sharedVideosRoot = "${sharedRoot}/videos";
  sharedMoviesRoot = "${sharedVideosRoot}/movies";
  sharedShowsRoot = "${sharedVideosRoot}/shows";
  sharedHomeVideosRoot = "${sharedVideosRoot}/home";
  sharedMusicVideosRoot = "${sharedVideosRoot}/music-videos";
  sharedYouTubeRoot = "${sharedVideosRoot}/youtube";
  sharedOtherVideosRoot = "${sharedVideosRoot}/other";
  userContentSubdirs = [
    "documents"
    "photos"
    "audiobooks"
    "books"
    "emails"
    "files"
    "uploads"
  ];
  sharedContentSubdirs = [
    "audiobooks"
    "books"
    "emails"
    "videos"
    "files"
  ];

  kanidmDomain = "id.${domain}";
  kanidmBaseUrl = "https://${kanidmDomain}";
  kanidmIssuer = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}";
  kanidmDiscoveryUrl = clientId: "${kanidmIssuer clientId}/.well-known/openid-configuration";
  runtimeAccessCanaries = {
    "canary-files" = {
      displayName = "Runtime Access Canary";
      mailAddress = "runtime-canary-files@${domain}";
      groups = [
        "users"
        "user-files"
        "shared-files-read-write-access"
        "paperless-users"
        "immich-users"
        "audiobookshelf-users"
        "kavita-users"
        "glances-users"
        "mail-archive-users"
        "metube-users"
      ];
      passwordSecret = "runtimeCanaryFilesPassword";
    };
  };
  glancesAccessUsers = [
    kanidmAdminUser
  ];
  monitorDomain = "${apps.monitoring.subdomain}.${domain}";
  paperlessDomain = "${apps.documents.subdomain}.${domain}";
  photosDomain = "${apps.photos.privateSubdomain}.${domain}"; # Private main Immich app hostname for owner login on LAN/NetBird.
  sharePhotosDomain = "${apps.photos.publicShareSubdomain}.${domain}"; # Public Immich share-link proxy hostname exposed through Cloudflare Tunnel.
  immichPublicProxyPort = networking.ports.immichPublicProxy;
  audiobooksDomain = "${apps.audiobooks.subdomain}.${domain}";
  vaultwardenDomain = "${apps.passwords.subdomain}.${domain}";
  uploadsDomain = "${apps.uploads.subdomain}.${domain}";
  filebrowserDomain = "${apps.files.subdomain}.${domain}";
  filebrowserPort = networking.ports.filebrowserQuantum;
  filebrowserStateDir = "/var/lib/filebrowser-quantum";
  emailsDomain = "${apps.mail.subdomain}.${domain}";
  kiwixDomain = "${apps.wiki.subdomain}.${domain}";
  kiwixLibraryRoot = "${dataRoot}/kiwix";
  kavitaDomain = "${apps.books.subdomain}.${domain}";
  jellyfinDomain = "${apps.videos.subdomain}.${domain}";
  metubeDomain = "${apps.downloads.subdomain}.${domain}";
}
