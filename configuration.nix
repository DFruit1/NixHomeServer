{ config, pkgs, lib, vars, ... }:

let
  systemPackages = with pkgs; [
    age
    bind
    cryptsetup
    gitMinimal
    gptfdisk
    hdparm
    jq
    lsof
    lvm2
    mdadm
    ncdu
    nix-output-monitor
    nixpkgs-fmt
    nvme-cli
    openssl
    parted
    pciutils
    python3
    ripgrep
    smartmontools
    sqlite
    usbutils
  ];
  extraBinaryCacheUrls = map (cache: cache.url) vars.binaryCaches;
  extraBinaryCachePublicKeys = map (cache: cache.publicKey) vars.binaryCaches;
  localAdminUser = config.nixhomeserver.localAdmin.user;
in
{
  ###############################################################################
  #  Core system bits (unchanged)
  ###############################################################################
  system.stateVersion = "25.05";
  boot.initrd.supportedFilesystems = [ "btrfs" "vfat" "zfs" ];
  # Load ZFS explicitly so the rebuilt system can manage the mirrored data pool
  # without depending on filesystem autodetection to pull the module in.
  boot.kernelModules = [ "jitterentropy_rng" "zfs" ];
  boot.initrd.kernelModules = [ "jitterentropy_rng" "crc32c-intel" "zfs" ];
  boot.initrd.availableKernelModules = [ "nvme" "ahci" "xhci_pci" "usb_storage" "sd_mod" ];
  boot.supportedFilesystems = [ "btrfs" "vfat" "zfs" ];
  networking = {
    hostName = vars.hostname;
    hostId = "84e8c12a";
    useDHCP = lib.mkForce false;
    defaultGateway = vars.serverLanGateway;
    nameservers = [ "127.0.0.1" ];
    hosts = {
      # Resolve the public Kanidm hostname locally on the server so internal
      # OIDC clients talk to Caddy directly instead of traversing Cloudflare.
      "127.0.0.1" = [ vars.kanidmDomain ];
      "::1" = [ vars.kanidmDomain ];
    };
    interfaces.${vars.netIface} = {
      useDHCP = lib.mkForce false;
      ipv4.addresses = [
        {
          address = vars.serverLanIP;
          prefixLength = vars.serverLanPrefixLength;
        }
      ];
    };
  };
  networking.networkmanager.enable = false;
  services.resolved.enable = false;
  time.timeZone = "Australia/Sydney";

  ###############################################################################
  #  Bootstrap layout declarations
  ###############################################################################
  imports = [
    ./disko-system.nix
    ./disko.nix
    ./secrets/agenix.nix
    ./modules/nixhomeserver/settings.nix
    ./modules/audiobookshelf
    ./modules/Core_Modules/caddy
    ./modules/Core_Modules/cloudflared
    ./modules/Core_Modules/data-disks
    ./modules/Core_Modules/impermanence
    ./modules/Core_Modules/kanidm
    ./modules/Core_Modules/netbird
    ./modules/Core_Modules/oauth2-proxy
    ./modules/Core_Modules/restic-state
    ./modules/Core_Modules/storage
    ./modules/Core_Modules/storage-monitoring
    ./modules/Core_Modules/unbound
    ./modules/copyparty
    ./modules/filebrowser-quantum
    ./modules/immich
    ./modules/jellyfin
    ./modules/kiwix
    ./modules/kavita
    ./modules/mail-archive
    ./modules/mail-archive-ui
    ./modules/metube
    ./modules/youtube-downloader
    ./modules/paperless
    ./modules/power-management
    ./modules/vaultwarden
  ];

  disko.enableConfig = true;
  repo.impermanence.enablePersistence = true;
  services.dbus.enable = true;
  services.zfs.autoScrub = {
    enable = true;
    pools = [ vars.zfsDataPool.name ];
  };
  systemd.services.dbus.stopIfChanged = true;

  systemd.tmpfiles.rules = [
    "d /run/secrets 0750 root root -"
  ];

  ###############################################################################
  #  ACME certificates
  ###############################################################################
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = vars.kanidmAdminEmail;
      dnsProvider = "cloudflare";
      credentialsFile = config.age.secrets.cfAPIToken.path;
      # Use a public recursive resolver for DNS-01 zone discovery. The local
      # split-horizon Unbound zone intentionally serves this domain without SOA
      # records, which confuses lego's Cloudflare zone lookup.
      dnsResolver = "9.9.9.9:53";
    };
    certs."${vars.domain}" = {
      extraDomainNames = [ "*.${vars.domain}" ];
      group = "caddy";
      reloadServices = [ "caddy.service" ];
    };
    certs."${vars.kanidmDomain}" = {
      group = "caddy";
      reloadServices = [ "caddy.service" "kanidm.service" ];
    };
  };

  # The host resolves via its own localhost Unbound instance, so ACME ordering
  # must wait for that resolver to be available before lego contacts Let's Encrypt.
  systemd.services = {
    "acme-order-renew-${vars.domain}" = {
      wants = [ "unbound.service" ];
      after = [ "unbound.service" ];
    };
    "acme-order-renew-${vars.kanidmDomain}" = {
      wants = [ "unbound.service" ];
      after = [ "unbound.service" ];
    };
  };

  ###############################################################################
  #  Secrets, users, bootstrap-SSH, etc.  (unchanged)
  ###############################################################################

  # bootstrap users & SSH   (your original block kept verbatim)
  users.users.root = {
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      vars.serverSSHPubKey
    ];
  };

  boot.loader.grub = {
    enable = true;
    efiSupport = true;
    efiInstallAsRemovable = true;
    device = "nodev";
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = false;

  #Use if you have issues with getting entropy
  # boot.kernelParams = [ "random.trust_cpu=on" ];

  hardware.cpu.intel.updateMicrocode = true;
  hardware.cpu.amd.updateMicrocode = true;

  networking.firewall.allowedTCPPorts = [ 22 ];

  services.openssh = {
    enable = true;
    openFirewall = false;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  users.users.${localAdminUser} = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      vars.serverSSHPubKey
    ];
  };

  services.btrfs.autoScrub.enable = true;
  programs.atop.enable = true;

  security.sudo.extraRules = [
    {
      users = [ localAdminUser ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  environment.systemPackages = systemPackages;

  nix = {
    package = pkgs.nixVersions.latest;
    settings = {
      substituters = [
        "https://cache.nixos.org"
        "https://nix-community.cachix.org"
      ] ++ extraBinaryCacheUrls;
      experimental-features = [ "nix-command" "flakes" ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ] ++ extraBinaryCachePublicKeys;
      trusted-users = [ "root" localAdminUser ];
      auto-optimise-store = true;
      builders-use-substitutes = true;
    };
  };
  nix.gc.automatic = true;
}
