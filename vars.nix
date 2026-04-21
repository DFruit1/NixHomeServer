{ lib, ... }:

rec {
  ############################################################
  # User-editable values
  ############################################################
  hostname = "server";
  domain = "sydneybasiniot.org";
  kanidmAdminUser = "admindsaw";
  kanidmAdminEmail = "dsaw@tuta.io";
  serverSSHPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server";

  serverLanIP = "192.168.8.12"; # Intended primary LAN IP for the server.
  serverLanPrefixLength = 24;
  serverLanGateway = "192.168.8.1";
  nbIP = "100.72.113.237";
  dnsMode = "split-horizon";
  lanDnsDomain = "home.arpa";
  lanDnsHosts = {
    "${hostname}" = serverLanIP;
    router = serverLanGateway;
  };
  netIface = "enp34s0";
  kanidmAuthSessionExpirySeconds = 259200; # 3 days

  mainDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E";
  zfsDataPool = {
    name = "data";
    mountPoint = "/mnt/data";
    mirrorPairs = [
      [
        "ata-HGST_HUS726T4TALA6L4_V1JAKPNH"
        "ata-HGST_HUS726T4TALA6L4_V6G7R6MS"
      ]
      [
        "ata-HGST_HUS726T4TALA6L4_V1J9PKDH"
        "ata-HGST_HUS726T4TALA6L4_V1G5K8YC"
      ]
    ];
    datasets = [
      "appdata"
      "media"
      "workspaces"
    ];
  };

  coldStorageMountPoint = "/mnt/cold-storage";
  coldStoragePools = [
    {
      name = "cold-v1jan8ph";
      disk = "ata-HGST_HUS726T4TALA6L4_V1JAN8PH";
      mountPoint = "${coldStorageMountPoint}/v1jan8ph";
    }
  ];

  cloudflareTunnelName = "metro";

  dataRoot = zfsDataPool.mountPoint;

  ############################################################
  # Shared derived values
  ############################################################
  splitDnsMode = dnsMode == "split-horizon";
  localDnsPrivateAnswer = if splitDnsMode then serverLanIP else nbIP;

  netbirdIface = "nb0";
  netbirdCidr = "100.64.0.0/10";
  wgPort = 51820;
  kanidmPort = 8443;

  zfsDataPoolDiskIds = lib.flatten zfsDataPool.mirrorPairs;
  monitoredDataDiskIds = zfsDataPoolDiskIds;
  monitoredColdStorageDiskIds = map (pool: pool.disk) coldStoragePools;
  monitoredStorageDiskIds = monitoredDataDiskIds ++ monitoredColdStorageDiskIds;

  appdataRoot = "${dataRoot}/appdata";
  mediaRoot = "${dataRoot}/media";
  workspaceRoot = "${dataRoot}/workspaces";
  usersWorkspaceRoot = "${workspaceRoot}/users";
  sharedWorkspaceRoot = "${workspaceRoot}/shared";

  ############################################################
  # Internal derived values
  ############################################################
  audiobookshelfDataDir = "${appdataRoot}/audiobookshelf";
  audiobookshelfConfigDir = "${audiobookshelfDataDir}/config";
  audiobookshelfMetadataDir = "${audiobookshelfDataDir}/metadata";
  audiobookshelfBackupDir = "${audiobookshelfMetadataDir}/backups";

  jellyfinDataDir = "${appdataRoot}/jellyfin/server";
  jellyfinLogDir = "${jellyfinDataDir}/log";
  jellyseerrConfigDir = "${appdataRoot}/jellyfin/jellyseerr";
  kavitaDataDir = "${appdataRoot}/kavita";
  paperlessDataDir = "${appdataRoot}/paperless";
  mailArchiveUiDataDir = "${appdataRoot}/mail-archive-ui";
  mailArchiveStoreRoot = "${dataRoot}/mail-archive";

  immichManagedPhotosRoot = "${mediaRoot}/photos/managed";
  immichExternalPhotosRoot = "${mediaRoot}/photos/external";
  paperlessConsumeDir = "${mediaRoot}/documents/consume";
  paperlessArchiveDir = "${mediaRoot}/documents/archive";
  paperlessExportDir = "${mediaRoot}/documents/export";
  audiobooksRoot = "${mediaRoot}/audio/audiobooks";
  podcastsRoot = "${mediaRoot}/audio/podcasts";
  ebooksRoot = "${mediaRoot}/books/ebooks";
  comicsRoot = "${mediaRoot}/books/comics";
  mangaRoot = "${mediaRoot}/books/manga";
  moviesRoot = "${mediaRoot}/video/movies";
  showsRoot = "${mediaRoot}/video/shows";
  homeVideosRoot = "${mediaRoot}/video/home";

  sharedExchangeRoot = "${sharedWorkspaceRoot}/exchange";
  sharedPublicRoot = "${sharedWorkspaceRoot}/public";
  photosUploadRoot = immichExternalPhotosRoot;
  documentsUploadRoot = paperlessConsumeDir;

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
  jellyseerrDomain = "jellyseerr.${domain}";
}
