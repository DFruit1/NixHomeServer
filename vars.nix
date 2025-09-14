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
  lanIP = "192.168.0.144";
  nbIP = "100.96.1.10";
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
  vaultwardenPort = 8222;
  homepagePort = 3005;
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
  # Kanidm issuer URL
  ############################################################
  kanidmDomain = "id.${domain}";
  kanidmIssuer = "https://id.${domain}";

  ############################################################
  # AppArmor allow‑paths
  ############################################################
  appArmorDefaults = {
    caddy = [ "/var/lib/caddy/**" "/var/log/caddy/**" "/etc/caddy/**" ];
    kanidm = [ "/var/lib/kanidm/**" "/var/log/kanidm/**" "/etc/kanidm/**" ];
    immich = [ "${dataRoot}/immich/**" "/var/log/immich/**" ];
    paperless = [ "${dataRoot}/paperless/**" "/var/log/paperless-ngx/**" ];
    audiobookshelf = [ "${dataRoot}/audiobookshelf/**" "/var/log/audiobookshelf/**" ];
    copyparty = [ "${dataRoot}/copyparty/**" "/var/log/copyparty/**" ];
    vaultwarden = [ "${dataRoot}/vaultwarden/**" "/var/log/vaultwarden/**" "/etc/vaultwarden/**" ];
    homepage = [ "${dataRoot}/homepage/**" "/var/log/homepage-dashboard/**" ];
  };
}
