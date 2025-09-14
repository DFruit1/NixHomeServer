{ config, pkgs, lib, vars, disko, ... }:

###############################################################################
#  Local helpers – were previously in diskconf.nix
###############################################################################
let
  mergerfsMountPoint = "/mnt/data";

  # build "/mnt/disk1:/mnt/disk2:…"
  mergerfsSourceList =
    lib.concatStringsSep ":"
      (lib.imap0
        (idx: _: "/mnt/disk${toString (idx + 1)}")
        vars.dataDisks);

  # build “data d1 /mnt/disk1” … for snapraid.conf
  mkSnapraidLine = idx: _:
    let n = toString (idx + 1); in
    "data d${n} /mnt/disk${n}";

in

{
  ###############################################################################
  #  Core system bits (unchanged)
  ###############################################################################
  system.stateVersion = "25.05";
  boot.initrd.supportedFilesystems = [ "btrfs" "xfs" "vfat" ];
  boot.kernelModules = [ "jitterentropy_rng" ];
  boot.initrd.kernelModules = [ "jitterentropy_rng" "crc32c-intel" ];
  boot.initrd.availableKernelModules = [ "nvme" "ahci" "xhci_pci" "usb_storage" "sd_mod" ];
  boot.supportedFilesystems = [ "btrfs" "xfs" "vfat" ];
  networking = {
    hostName = vars.hostname;
    defaultGateway = vars.defaultGateway;
    nameservers = vars.nameservers;
    interfaces.enp34s0 = {
      ipv4.addresses = [
        { address = vars.lanIP; prefixLength = 24; }
      ];
    };
  };
  time.timeZone = "Australia/Sydney";

  ###############################################################################
  #  Disko – layout + engine
  ###############################################################################
  imports = [
    ./disko.nix # your actual disk layout
    ./modules/homepage
    ./modules/audiobookshelf
    ./modules/caddy
    ./modules/cloudflared
    ./modules/copyparty
    ./modules/oauth2-proxy
    ./modules/immich
    ./modules/kanidm
    ./modules/netbird
    ./modules/paperless
    ./modules/unbound
    ./modules/vaultwarden
  ];

  disko.enableConfig = true;
  services.dbus.enable = true;
  systemd.services.dbus.stopIfChanged = true;

  ###############################################################################
  #  SnapRAID / mergerfs (formerly diskconf.nix)
  ###############################################################################
  environment.systemPackages = with pkgs; [
    mergerfs
    snapraid
    smartmontools
  ];

  fileSystems = {
    "${mergerfsMountPoint}" = {
      fsType = "fuse.mergerfs";
      device = mergerfsSourceList;
      options =
        [
          "defaults"
          "allow_other"
          "use_ino"
          "minfreespace=10G"
          "category.create=epmfs"
        ]
        ++ (lib.imap0 (idx: _: "x-systemd.requires=/mnt/disk${toString (idx + 1)}") vars.dataDisks)
        ++ (lib.imap0 (idx: _: "x-systemd.after=/mnt/disk${toString (idx + 1)}") vars.dataDisks);
    };
  };

  systemd.tmpfiles.rules = [
    "d ${mergerfsMountPoint} 0755 root root -"
  ];

  environment.etc."snapraid.conf".text = ''
    parity /mnt/parity/snapraid.parity
    ${builtins.concatStringsSep "\n" (lib.imap0 mkSnapraidLine vars.dataDisks)}
    exclude *.unrecoverable
    exclude /tmp/
    exclude lost+found/
  '';

  # timers
  systemd.timers.snapraid-sync = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
  };
  systemd.timers.snapraid-scrub = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "weekly"; Persistent = true; };
  };

  # services
  systemd.services.snapraid-sync = {
    description = "Sync SnapRAID arrays";
    serviceConfig = {
      Type = "oneshot";
      RequiresMountsFor = [ mergerfsMountPoint "/mnt/parity" ];
    };
    path = [ pkgs.snapraid ];
    script = "snapraid sync";
  };

  systemd.services.snapraid-scrub = {
    description = "Scrub SnapRAID arrays";
    serviceConfig = {
      Type = "oneshot";
      RequiresMountsFor = [ mergerfsMountPoint "/mnt/parity" ];
    };
    path = [ pkgs.snapraid ];
    script = "snapraid scrub -p 1 -o 10";
  };

  services.smartd = {
    enable = true;
    devices = map (id: { device = "/dev/disk/by-id/${id}"; })
      (vars.dataDisks ++ [ vars.parityDisk ]);
  };

  ###############################################################################
  #  ACME certificates
  ###############################################################################
  security.acme = {
    acceptTerms = true;
    defaults = {
      email = vars.email;
      dnsProvider = "cloudflare";
      credentialsFile = config.age.secrets.cfApiToken.path;
    };
    certs."${vars.kanidmDomain}" = {
      group = "caddy";
    };
  };

  ###############################################################################
#  Secrets, users, bootstrap-SSH, etc.  (unchanged)
  ###############################################################################
  #Manually copy the private key to this location, with 0400 permissions
  age.identityPaths = [ "/etc/agenix/age.key" ];

  age.secrets = {
    netbirdSetupKey = { file = ./secrets/netbirdSetupKey.age; owner = "netbird-main"; mode = "0400"; };
    cfHomeCreds = { file = ./secrets/cfHomeCreds.age; owner = "cloudflared"; group = "cloudflared"; mode = "0400"; };
    cfApiToken = { file = ./secrets/cfApiToken.age; owner = "root"; group = "caddy"; mode = "0440"; };
    kanidmAdminPass = { file = ./secrets/kanidmAdminPass.age; owner = "kanidm"; mode = "0400"; };
    kanidmSysAdminPass = { file = ./secrets/kanidmSysAdminPass.age; owner = "kanidm"; mode = "0400"; };
    immichClientSecret = { file = ./secrets/immichClientSecret.age; owner = "immich"; mode = "0400"; };
    paperlessClientSecret = { file = ./secrets/paperlessClientSecret.age; owner = "paperless"; group = "paperless"; mode = "0400"; };
    absClientSecret = { file = ./secrets/absClientSecret.age; owner = "audiobookshelf"; mode = "0400"; };
    vaultwardenClientSecret = { file = ./secrets/vaultwardenClientSecret.age; owner = "vaultwarden"; mode = "0400"; };
    vaultwardenAdminToken = { file = ./secrets/vaultwardenAdminToken.age; owner = "vaultwarden"; mode = "0400"; };
    oauth2ProxyClientSecret = { file = ./secrets/oauth2ProxyClientSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    oauth2ProxyCookieSecret = { file = ./secrets/oauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    copypartyClientSecret = { file = ./secrets/copypartyClientSecret.age; owner = "copyparty"; mode = "0400"; };
    vaultwardenClientSecret = { file = ./secrets/vaultwardenClientSecret.age; owner = "vaultwarden"; mode = "0400"; };
    vaultwardenAdminToken = { file = ./secrets/vaultwardenAdminToken.age; owner = "vaultwarden"; mode = "0400"; };
  };

  # bootstrap users & SSH   (your original block kept verbatim)
  users.users.root = {
    initialPassword = "root";
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server"
    ];
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

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

  hardware.enableAllFirmware = true;
  nixpkgs.config.allowUnfree = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true; # bootstrap only
      PermitRootLogin = "yes";
    };
    openFirewall = true;
  };

  users.users.dsaw = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    shell = pkgs.bashInteractive;
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDECt+GBZcPahwDCtWiMgn24qGdqMOJhP/pHo/pKsHAF From PC desktop into Home Server"
    ];
  };

  services.btrfs.autoScrub.enable = true;

  nix.gc.automatic = true;
}
