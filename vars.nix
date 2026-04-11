{ lib, ... }:

rec {
  ############################################################
  # Once everything is defined, run the following command:
  #  nixos-anywhere --flake .#server --generate-hardware-config nixos-generate-config ./hardware-configuration.nix root@192.168.0.144
  ############################################################
  hostname = "server";
  domain = "sydneybasiniot.org";
  email = "dsaw@tuta.io";
  serverSSHPubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server";

  # LAN & NetBird addresses for server
  serverLanIP = "192.168.0.144";
  enableDietPiCompanion = false;
  piLanIP = "192.168.0.123";
  # Authoritative target for private service DNS names; refresh with
  # `ip -brief addr show nb0` if NetBird reassigns it.
  nbIP = "100.72.113.237";
  defaultGateway = "192.168.0.1";
  dnscryptListenAddress = "127.0.0.1";
  dnscryptListenPort = 5053;
  dnscryptForwardAddress = "127.0.0.1";
  primaryNameServers = [ dnscryptForwardAddress ];
  fallbackNameServers = [ "9.9.9.9" "1.1.1.1" ];
  netIface = "enp34s0";
  netbirdIface = "nb0";
  netbirdCidr = "100.64.0.0/10";

  ############################################################
  # PORTS – Edit here to avoid conflicts
  ############################################################
  wgPort = 51820;
  kanidmPort = 8443;
  immichPort = 2283;
  paperlessPort = 8000;
  audiobookshelfPort = 13378;
  copypartyPort = 3923;
  kavitaPort = 5000;
  jellyfinPort = 8096;
  jellyseerrPort = 5055;
  oauth2ProxyPort = 4180;

  ############################################################
  # Disk UUIDs (examples – REPLACE)
  # Run ls -l /dev/disk/by-id/ and insert name of each entry, identified by ata-<Vendor>_<Model>_<Serial>
  ############################################################
  mainDisk = "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E";
  dataDisks = [
    "ata-HGST_HUS726T4TALA6L4_V6G7R6MS" #sda
    "ata-HGST_HUS726T4TALA6L4_V1JAKPNH" #sdc
    "ata-HGST_HUS726T4TALA6L4_V1J9PKDH" #sdf
    "ata-HGST_HUS726T4TALA6L4_V1JAN8PH" #sdg
    "ata-HGST_HUS726T4TALA6L4_V1G5K8YC" #sde
  ];
  parityDisk = "ata-HGST_HUS726040ALA610_K7G5W29L"; #sdd

  ############################################################
  # Cloudflare Tunnel info
  ############################################################
  cloudflareTunnelName = "metro";
  cloudflareTunnelID = "83990257-d193-42ca-94cc-6cd9b79beaf7";
  cloudflareAccountID = "a047e5f7e2a9bfa39439b4ef13fa9589";

  ############################################################
  # Paths
  ############################################################
  dataRoot = "/mnt/data";

  ############################################################
  # Kanidm OAuth2 / OIDC URLs
  # Kanidm uses client-specific issuer and discovery URLs.
  ############################################################
  kanidmDomain = "id.${domain}";
  kanidmBaseUrl = "https://${kanidmDomain}";
  kanidmAuthorizeUrl = "${kanidmBaseUrl}/ui/oauth2";
  kanidmTokenUrl = "${kanidmBaseUrl}/oauth2/token";
  kanidmIssuer = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}";
  kanidmDiscoveryUrl = clientId: "${kanidmIssuer clientId}/.well-known/openid-configuration";
  kanidmUserInfoUrl = clientId: "${kanidmBaseUrl}/oauth2/openid/${clientId}/userinfo";
  kavitaDomain = "kavita.${domain}";
  jellyfinDomain = "jellyfin.${domain}";
  jellyseerrDomain = "jellyseerr.${domain}";

}
