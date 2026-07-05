{ pkgs, lib, vars, ... }:

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
  localAdminUser = vars.localAdminUser;
  isX86 = builtins.elem pkgs.stdenv.hostPlatform.system [
    "i686-linux"
    "x86_64-linux"
  ];
in
{
  system.stateVersion = "25.05";

  boot.initrd.supportedFilesystems = [ "btrfs" "vfat" ]
    ++ lib.optional vars.enableZfsDataPool "zfs";
  boot.kernelModules = [ "jitterentropy_rng" ]
    ++ lib.optional vars.enableZfsDataPool "zfs";
  boot.initrd.kernelModules = [ "jitterentropy_rng" ]
    ++ lib.optional vars.enableZfsDataPool "zfs";
  boot.initrd.availableKernelModules = [ "nvme" "ahci" "xhci_pci" "usb_storage" "sd_mod" ];
  boot.supportedFilesystems = [ "btrfs" "vfat" "ext4" ]
    ++ lib.optional vars.enableZfsDataPool "zfs";

  networking = {
    hostName = vars.hostname;
    hostId = vars.hostId;
    useDHCP = lib.mkForce false;
    defaultGateway = vars.serverLanGateway;
    nameservers = [ "127.0.0.1" ];
    hosts = {
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
  time.timeZone = vars.timeZone;

  services.dbus.enable = true;

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

  hardware.cpu.intel.updateMicrocode = isX86;
  hardware.cpu.amd.updateMicrocode = isX86;

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

  security.sudo.extraRules = [
    {
      users = [ localAdminUser ];
      commands = [
        {
          # Guarded deploy and bootstrap scripts still invoke ordinary sudo
          # for nixos-rebuild, systemd status, and detached switch activation.
          # This broad deploy contract is tracked separately from identity tooling
          # while local admin hardening is handled in deploy flow policy.
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
