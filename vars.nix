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
  lanDnsDomain = "home.arpa";
  lanDnsHosts = { # LAN-only forward and reverse records served by Unbound.
    "${hostname}" = serverLanIP;
    router = serverLanGateway;
  };
  netIface = "enp34s0";
  kanidmAuthSessionExpirySeconds = 259200; # Kanidm auth session lifetime in seconds.

  mainDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"; # System SSD by-id value.
  zfsDataPool = { # Active mirrored ZFS pool created by the data-disk wrapper.
    name = "data";
    mountPoint = "/mnt/data";
    mirrorPairs = [
      [
        "ata-HGST_HUS726T4TALA6L4_V1JAKPNH"
        "ata-HGST_HUS726T4TALA6L4_V1J9PKDH"
      ]
    ];
    datasets = [
      "media"
      "users"
      "shared"
    ];
  };

  coldStorageMountPoint = "/mnt/cold-storage";
  coldStoragePools = [ ]; # Optional manual-import pools kept outside the default Disko path.

  cloudflareTunnelName = "metro";

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs;
  monitoredDataDiskIds = zfsDataPoolDiskIds;
  monitoredColdStorageDiskIds = map (pool: pool.disk) coldStoragePools;
  monitoredStorageDiskIds = monitoredDataDiskIds ++ monitoredColdStorageDiskIds;

  dataRoot = zfsDataPool.mountPoint;
  mediaRoot = "${dataRoot}/media";
  usersRoot = "${dataRoot}/users";
  sharedRoot = "${dataRoot}/shared";
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
    "documents"
    "photos"
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
