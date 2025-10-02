{ config, pkgs, lib, vars, disko, ... }:

###############################################################################
#  Local helpers – were previously in diskconf.nix
###############################################################################
let
  mergerfsMountPoint = "/mnt/data";
  snapraidContentDir = "/persist/snapraid";
  parityMountPoint = "/mnt/parity";

  parityEnabled = vars.parityDisk != null && vars.parityDisk != "";

  dataMountPoints =
    lib.imap0 (idx: _: "/mnt/disk${toString (idx + 1)}") vars.dataDisks;

  # build "/mnt/disk1:/mnt/disk2:…"
  mergerfsSourceList = lib.concatStringsSep ":" dataMountPoints;

  # build “data d1 /mnt/disk1” … for snapraid.conf
  mkSnapraidLine = idx: _:
    let n = toString (idx + 1); in
    "data d${n} /mnt/disk${n}";

  snapraidContentPaths =
    [ "${snapraidContentDir}/snapraid.content" ]
    ++ (builtins.map (path: "${path}/snapraid.content") dataMountPoints)
    ++ (lib.optional parityEnabled "${parityMountPoint}/snapraid.content");

  snapraidContentLines = builtins.map (path: "content ${path}") snapraidContentPaths;

  diskMountOptions =
    lib.listToAttrs
      (builtins.map
        (mountPoint: {
          name = mountPoint;
          value = {
            options = lib.mkAfter [ "nofail" "x-systemd.device-timeout=1s" ];
            neededForBoot = lib.mkDefault false;
          };
        })
        dataMountPoints);

  parityMountOptions = lib.optionalAttrs parityEnabled {
    "${parityMountPoint}" = {
      options = lib.mkAfter [ "nofail" "x-systemd.device-timeout=1s" ];
      neededForBoot = lib.mkDefault false;
    };
  };

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
      [
        ./hardware-configuration.nix
        ./disko.nix
        ./secrets/agenix.nix
      ] ++ modulePaths;

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

  fileSystems = lib.mkMerge [
    {
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
          ++ (builtins.map (path: "x-systemd.after=${path}") dataMountPoints);
        neededForBoot = lib.mkDefault false;
      };
    }
    diskMountOptions
    parityMountOptions
  ];

  systemd.tmpfiles.rules = [
    "d ${mergerfsMountPoint} 0755 root root -"
  ]
  ++ (builtins.map (path: "d ${path} 0755 root root -") dataMountPoints)
  ++ (lib.optional parityEnabled "d ${parityMountPoint} 0755 root root -")
  ++ [
    "d /run/secrets 0750 root root -"
    "d ${snapraidContentDir} 0755 root root -"
  ];

  environment.etc."snapraid.conf".text = ''
    ${lib.optionalString parityEnabled "parity ${parityMountPoint}/snapraid.parity"}
    ${builtins.concatStringsSep "\n" snapraidContentLines}
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
      RequiresMountsFor = [ mergerfsMountPoint ]
        ++ (lib.optional parityEnabled parityMountPoint);
    };
    path = [ pkgs.snapraid ];
    script = "snapraid sync";
  };

  systemd.services.snapraid-scrub = {
    description = "Scrub SnapRAID arrays";
    serviceConfig = {
      Type = "oneshot";
      RequiresMountsFor = [ mergerfsMountPoint ]
        ++ (lib.optional parityEnabled parityMountPoint);
    };
    path = [ pkgs.snapraid ];
    script = "snapraid scrub -p 1 -o 10";
  };

  services.smartd = {
    enable = true;
    devices = map (id: { device = "/dev/disk/by-id/${id}"; })
      (vars.dataDisks ++ lib.optional parityEnabled vars.parityDisk);
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
    efiInstallAsRemovable = false;
    device = "nodev";
  };
  boot.loader.systemd-boot.enable = lib.mkForce false;
  boot.loader.efi.canTouchEfiVariables = true;

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
