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
    nameservers = vars.primaryNameServers;
    interfaces.enp34s0 = {
      ipv4.addresses = [
        { address = vars.lanIP; prefixLength = 24; }
      ];
    };
    networkmanager = {
      enable = true;
      dns = "none";
    };
  };
  services.resolved.enable = false;
  time.timeZone = "Australia/Sydney";

  ###############################################################################
  #  Disko – layout + engine
  ###############################################################################
  # Import all modules found in the modules/ directory
  imports =
    let
      modulePaths = builtins.map (name: ./modules + "/${name}" )
        (builtins.attrNames (builtins.readDir ./modules));
    in
      [ ./disko.nix ./secrets/agenix.nix ] ++ modulePaths;

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
      credentialsFile = config.age.secrets.cfAPIToken.path;
    };
    certs."${vars.kanidmDomain}" = {
      group = "caddy";
    };
  };

  ###############################################################################
#  Secrets, users, bootstrap-SSH, etc.  (unchanged)
  ###############################################################################

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
