{ lib, ... }:

rec {
  hostname = "server";
  domain = "sydneybasiniot.org";
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
      "workspaces"
      "mail-archive"
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
  usersWorkspaceRoot = "${dataRoot}/users";
  sharedPublicRoot = "${dataRoot}/shared";
  userBooksSubdirs = [
    "ebooks"
    "comics"
    "manga"
  ];
  userVideoSubdirs = [
    "movies"
    "shows"
    "home"
  ];
  sharedBooksSubdirs = userBooksSubdirs;
  sharedVideoSubdirs = userVideoSubdirs;
  sharedAudiobooksRoot = "${sharedPublicRoot}/audiobooks";
  sharedBooksRoot = "${sharedPublicRoot}/books";
  sharedEbooksRoot = "${sharedBooksRoot}/ebooks";
  sharedComicsRoot = "${sharedBooksRoot}/comics";
  sharedMangaRoot = "${sharedBooksRoot}/manga";
  sharedEmailsRoot = "${sharedPublicRoot}/emails";
  sharedVideosRoot = "${sharedPublicRoot}/videos";
  sharedMoviesRoot = "${sharedVideosRoot}/movies";
  sharedShowsRoot = "${sharedVideosRoot}/shows";
  sharedHomeVideosRoot = "${sharedVideosRoot}/home";
  userContentSubdirs = [
    "documents"
    "photos"
    "audiobooks"
    "books"
    "videos"
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
  audiobooksDomain = "audiobooks.${domain}";
  filesDomain = "files.${domain}";
  emailsDomain = "emails.${domain}";
  kavitaDomain = "books.${domain}";
  jellyfinDomain = "videos.${domain}";
}
