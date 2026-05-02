{ lib, ... }:

rec {
  hostname = "server";
  domain = "sydneybasiniot.org";
  paperlessEnableDangerousMacroOfficeParsing = false;
  paperlessOcrLanguage = "eng";
  kanidmAdminUser = "admindsaw";
  kanidmAdminEmail = "dsaw@tuta.io";
  serverSSHPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server";

  serverLanIP = "192.168.8.12"; # Primary LAN IP to assign to the host.
  serverLanPrefixLength = 24;
  serverLanGateway = "192.168.8.1"; # Default IPv4 gateway for the LAN uplink.
  nbIP = "100.72.113.237";
  dnsMode = "split-horizon"; # Either "split-horizon" or "netbird-only".
  dnsPrivacyMode = "encrypted-only"; # Keep recursive upstream DNS on encrypted transports only.
  lanDnsDomain = "home.arpa";
  lanDnsHosts = { # LAN-only forward and reverse records served by Unbound.
    "${hostname}" = serverLanIP;
    router = serverLanGateway;
  };
  netIface = "enp34s0";
  kanidmAuthSessionExpirySeconds = 259200; # Kanidm auth session lifetime in seconds.

  mainDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"; # Live system SSD by-id value used for runtime protection and monitoring.
  zfsDataPool = { # Active mirrored ZFS pool metadata. Member IDs are retained for bootstrap-era workflows only.
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

  coldStorageMountPoint = "/mnt/cold-storage";
  coldStoragePools = [ ]; # Optional manual-import pools kept outside the default Disko path.

  cloudflareTunnelName = "metro";
  binaryCaches = [ ]; # Optional extra binary caches: [{ url = "https://example.cachix.org"; publicKey = "example.cachix.org-1:..."; }]

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs; # Bootstrap-era pool member IDs retained for blank-machine provisioning metadata.

  dataRoot = zfsDataPool.mountPoint;
  paperlessRoot = "${dataRoot}/paperless";
  paperlessInboxRoot = "${paperlessRoot}/inbox";
  paperlessArchiveRoot = "${paperlessRoot}/archive";
  paperlessExportRoot = "${paperlessRoot}/export";
  paperlessMailArchiveConsumeRoot = "${paperlessInboxRoot}/mail-archive";
  paperlessMailArchiveStagingRoot = "${paperlessRoot}/.mail-archive-paperless-staging";
  immichRoot = "${dataRoot}/immich";
  immichManagedRoot = "${immichRoot}/managed";
  immichExternalRoot = "${immichRoot}/external";
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
  fileAccessPosixGids = {
    "user-files" = 2001;
    "shared-files-ro" = 2002;
    "shared-files-rw" = 2003;
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
    {
      dir = "other";
      type = 2;
      fileGroupTypes = [ 2 3 1 ];
      label = "Other";
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
  sharedOtherBooksRoot = "${sharedBooksRoot}/other";
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
  photosDomain = "photos.${domain}";
  sharePhotosDomain = "sharephotos.${domain}";
  audiobooksDomain = "audiobooks.${domain}";
  filesDomain = "files.${domain}";
  emailsDomain = "emails.${domain}";
  kiwixDomain = "wiki.${domain}";
  kiwixLibraryRoot = "${dataRoot}/kiwix";
  kavitaDomain = "books.${domain}";
  jellyfinDomain = "videos.${domain}";
  metubeDomain = "ytdownload.${domain}";
}
