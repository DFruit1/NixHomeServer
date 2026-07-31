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
  localAdminUser = vars.localAdminUser;
  isX86 = builtins.elem pkgs.stdenv.hostPlatform.system [
    "i686-linux"
    "x86_64-linux"
  ];
  nixStoreCapacityGc = pkgs.writeShellApplication {
    name = "nixhomeserver-nix-store-capacity-gc";
    runtimeInputs = [
      pkgs.coreutils
      config.nix.package
      pkgs.util-linux
    ];
    text = builtins.readFile ../../../scripts/helpers/nix-store-capacity-gc.sh;
  };
  nixStoreCapacityGcStopPost = pkgs.writeShellScript "nix_store_gc_failed-stop-post" ''
    failure_marker=/run/nixhomeserver-nix-gc/helper-failure-reported
    if [[ "''${SERVICE_RESULT:-success}" == success || -e "$failure_marker" ]]; then
      exit 0
    fi
    invocation_id="''${INVOCATION_ID:-manual}"
    if [[ ! "$invocation_id" =~ ^[A-Fa-f0-9]{16,64}$ ]]; then
      invocation_id=manual
    fi
    printf >&2 \
      '{"event":"nix_store_gc_failed","invocation_id":"%s","stage":"systemd","service_result":"%s","exit_code":"%s","exit_status":"%s"}\n' \
      "$invocation_id" \
      "''${SERVICE_RESULT:-unknown}" \
      "''${EXIT_CODE:-unknown}" \
      "''${EXIT_STATUS:-unknown}"
  '';
in
{
  system.stateVersion = "25.05";

  boot.initrd.supportedFilesystems = [ "btrfs" "ext4" "vfat" ]
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
  # Root is Btrfs/ext4; never force-import a potentially foreign ZFS pool as a
  # root pool during boot. The managed data pool is reconciled separately.
  boot.zfs.forceImportRoot = false;

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

  # Keep the generated recovery credential functional for local-console login
  # and any future sudo policy that requires authentication. SSH password login
  # remains disabled, so this does not add a network password-authentication path.
  systemd.services.local-admin-bootstrap-password = {
    description = "Reconcile the local administrator recovery password";
    wantedBy = [ "multi-user.target" ];
    before = [ "systemd-user-sessions.service" ];
    restartTriggers = [ config.age.secrets.serverBootstrapSudoPassword.file ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "30s";
      LoadCredential = [
        "bootstrap-password:${config.age.secrets.serverBootstrapSudoPassword.path}"
      ];
      UMask = "0077";
      PrivateTmp = true;
    };
    script = ''
      set -euo pipefail
      password="$(<"$CREDENTIALS_DIRECTORY/bootstrap-password")"
      if [[ -z "$password" || "$password" == *:* || "$password" == *$'\n'* ]]; then
        echo "Invalid local administrator recovery password" >&2
        exit 1
      fi
      printf '%s:%s\n' ${lib.escapeShellArg localAdminUser} "$password" \
        | ${pkgs.shadow}/bin/chpasswd
    '';
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
      ];
      experimental-features = [ "nix-command" "flakes" ];
      trusted-public-keys = [
        "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      ];
      trusted-users = [ "root" localAdminUser ];
      auto-optimise-store = false;
      builders-use-substitutes = true;
      # Keep the daemon capable of accepting a later one-shot or newly selected
      # distributed build even when the current deploy allocation is local-only.
      # The deploy helper omits this host from its builders list in local mode.
      max-jobs =
        if vars.buildSlots.remote == 0 then "auto"
        else vars.buildSlots.remote;
      cores = vars.buildCores.remote;
    };
  };

  nix.gc.automatic = false;
  nix.optimise.automatic = false;

  systemd.services.nixhomeserver-nix-gc = {
    description = "Capacity-triggered Nix store garbage collection";
    environment = {
      NIX_STORE_MAX_GIB = toString vars.nixStoreMaxSizeGiB;
      NIX_GC_RETENTION_DAYS = toString vars.nixGcRetentionDays;
      NIX_GC_FAILURE_MARKER = "/run/nixhomeserver-nix-gc/helper-failure-reported";
    };
    unitConfig = {
      OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      OnFailureJobMode = "replace-irreversibly";
    };
    serviceConfig = {
      Type = "oneshot";
      ExecStartPre = "${pkgs.coreutils}/bin/rm -f /run/nixhomeserver-nix-gc/helper-failure-reported";
      ExecStart = "${nixStoreCapacityGc}/bin/nixhomeserver-nix-store-capacity-gc";
      ExecStopPost = nixStoreCapacityGcStopPost;
      Nice = 15;
      CPUWeight = 10;
      IOWeight = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      MemoryHigh = "1G";
      MemoryMax = "2G";
      PrivateTmp = true;
      RuntimeDirectory = "nixhomeserver-nix-gc";
      TimeoutStartSec = "4h";
      SuccessExitStatus = [ 75 ];
      UMask = "0077";
    };
  };

  systemd.timers.nixhomeserver-nix-gc = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "hourly";
      Persistent = true;
      RandomizedDelaySec = "10m";
    };
  };

  systemd.services.nixhomeserver-nix-optimise = {
    description = "Low-priority weekly Nix store optimisation";
    path = [ pkgs.nix pkgs.util-linux ];
    unitConfig = {
      StartLimitIntervalSec = "6h";
      StartLimitBurst = 2;
    };
    serviceConfig = {
      Type = "oneshot";
      Nice = 15;
      CPUWeight = 10;
      IOWeight = 10;
      IOSchedulingClass = "best-effort";
      IOSchedulingPriority = 7;
      MemoryHigh = "1G";
      MemoryMax = "2G";
      TimeoutStartSec = "6h";
      Restart = "on-failure";
      RestartSec = "30min";
      SuccessExitStatus = [ 75 ];
    };
    script = ''
      set -euo pipefail
      exec 9>/run/lock/nixhomeserver-maintenance.lock
      flock -n 9 || { echo "Another maintenance job is active" >&2; exit 75; }
      exec nix store optimise
    '';
  };

  systemd.timers.nixhomeserver-nix-optimise = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "Sun *-*-* 07:00:00";
      Persistent = true;
      RandomizedDelaySec = "45m";
    };
  };
}
