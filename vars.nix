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

  serverLanIP = "192.168.8.12"; # Router-reserved LAN IP used for DNS/docs, not a static interface assignment.
  nbIP = "100.72.113.237";
  dnsMode = "netbird-only";
  netIface = "enp34s0";

  mainDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E";
  dataDisks = [
    "ata-HGST_HUS726T4TALA6L4_V6G7R6MS" # sda
    "ata-HGST_HUS726T4TALA6L4_V1JAKPNH" # sdc
    "ata-HGST_HUS726T4TALA6L4_V1J9PKDH" # sdf
    "ata-HGST_HUS726T4TALA6L4_V1JAN8PH" # sdg
    "ata-HGST_HUS726T4TALA6L4_V1G5K8YC" # sde
  ];
  parityDisk = "ata-HGST_HUS726040ALA610_K7G5W29L"; # sdd

  enableBackups = true;
  enableBackupDisk = false;
  backupDisk = null;

  cloudflareTunnelName = "metro";
  cloudflareTunnelID = "83990257-d193-42ca-94cc-6cd9b79beaf7";
  cloudflareAccountID = "a047e5f7e2a9bfa39439b4ef13fa9589";

  dataRoot = "/mnt/data";
  primaryDataRoot = "/mnt/disk1";
  backupMountPoint = "/mnt/backup";

  ############################################################
  # Shared derived values
  ############################################################
  splitDnsMode = dnsMode == "split-horizon";
  localDnsPrivateAnswer = if splitDnsMode then serverLanIP else nbIP;

  netbirdIface = "nb0";
  netbirdCidr = "100.64.0.0/10";
  wgPort = 51820;
  kanidmPort = 8443;

  backupRepository = "${backupMountPoint}/restic/server-state";

  appdataRoot = "${dataRoot}/appdata";
  mediaRoot = "${dataRoot}/media";
  workspaceRoot = "${dataRoot}/workspaces";
  usersWorkspaceRoot = "${workspaceRoot}/users";
  sharedWorkspaceRoot = "${workspaceRoot}/shared";
  workspaceDataRoot = "${primaryDataRoot}/workspaces";
  usersWorkspaceDataRoot = "${workspaceDataRoot}/users";
  sharedWorkspaceDataRoot = "${workspaceDataRoot}/shared";
  mediaDataRoot = "${primaryDataRoot}/media";

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
  mailArchiveStoreRoot = "${primaryDataRoot}/mail-archive";

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
  sharedExchangeDataRoot = "${sharedWorkspaceDataRoot}/exchange";
  sharedPublicDataRoot = "${sharedWorkspaceDataRoot}/public";
  photosUploadDataRoot = "${mediaDataRoot}/photos/external";
  documentsUploadDataRoot = "${mediaDataRoot}/documents/consume";

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
