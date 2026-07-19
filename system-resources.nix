{ config, lib, pkgs, vars, ... }:

let
  power = {
    enable = true;
    cpuGovernor = "powersave";
    nightlySuspend = {
      # Keep disabled unless RTC wake has been verified on the target hardware.
      # While suspended, Cloudflare Tunnel, DNS, and all hosted services are offline.
      enable = false;
      calendar = "*-*-* 04:30:00"; # Suspend after normal overnight maintenance timers have started.
      wakeTime = "06:00";
    };
    skipIfSshSessions = true;
    skipIfOtherUserSessions = true;
    blockerUnits =
      [
        "storage-smart-long.service"
        "storage-smart-short.service"
      ]
      ++ lib.optionals vars.enableZfsDataPool [
        "zfs-scrub.service"
      ]
      ++ lib.optionals (vars.storageProfile == "zfs-mirror") [ "btrfs-scrub--.service" ];
    wakeOnLan = {
      enable = true;
      interface = vars.network.lanInterface;
      policy = [ "magic" ];
    };
    powertopAutoTune = false; # Broad auto-tuning can be too aggressive for a storage server.
    scsiLinkPolicy = null; # Keep the kernel default for SATA/SCSI link power management.
    usbAutoSuspend = {
      enable = false;
      denyList = [ ];
    };
    fstrimCalendar = "Sun *-*-* 19:00:00";
  };

  usbCfg = power.usbAutoSuspend;
  kernelPackages = config.boot.kernelPackages;
  isX86 = builtins.elem pkgs.stdenv.hostPlatform.system [
    "i686-linux"
    "x86_64-linux"
  ];
  hasModule = name: config.nixhomeserver.modules.${name} or false;
  moduleEnabled = name: hasModule name && (config.repo.${name}.enable or true);
  nightlySuspend = power.nightlySuspend;

  usbDenyRule = device:
    let
      deviceName =
        if device ? name then
          " ${device.name}"
        else
          "";
    in
    ''
      # Keep${deviceName} on full USB power.
      ACTION=="add|bind", SUBSYSTEM=="usb", ATTR{idVendor}=="${device.idVendor}", ATTR{idProduct}=="${device.idProduct}", TEST=="power/control", ATTR{power/control}="on"
    '';

  usbAutoSuspendRules =
    if usbCfg.enable then
      ''
        # Default new USB devices to autosuspend unless they are explicitly denied.
        ACTION=="add", SUBSYSTEM=="usb", TEST=="power/control", ATTR{power/control}="auto"
      ''
      + lib.concatMapStringsSep "\n" usbDenyRule usbCfg.denyList
    else
      "";

  blockerUnits = lib.escapeShellArgs power.blockerUnits;
  wakeTime = lib.escapeShellArg nightlySuspend.wakeTime;
  nightlySuspendPath = with pkgs; [
    coreutils
    gawk
    gnugrep
    procps
    systemd
    util-linux
  ];
  systemPackages =
    (with pkgs; [
      ethtool
      pciutils
      powertop
      usbutils
    ])
    ++ [
      kernelPackages.cpupower
    ]
    ++ lib.optional isX86 kernelPackages.turbostat;
in
lib.mkMerge [
  {
    zramSwap = {
      enable = true;
      memoryPercent = 25;
      algorithm = "zstd";
      priority = 5;
    };

    boot.extraModprobeConfig = lib.optionalString vars.enableZfsDataPool ''
      options zfs zfs_arc_min=536870912 zfs_arc_max=4294967296
    '';

    services.journald.extraConfig = ''
      SystemMaxUse=512M
      RuntimeMaxUse=128M
      SystemKeepFree=2G
      MaxRetentionSec=30day
    '';

    boot.kernel.sysctl = {
      "fs.inotify.max_user_watches" = 524288;
      "fs.inotify.max_user_instances" = 1024;
    };

    systemd.services =
      lib.optionalAttrs (hasModule "immich") {
      immich-machine-learning.serviceConfig = {
        MemoryHigh = "4G";
        MemoryMax = "6G";
        CPUQuota = "250%";
      };
      immich-server.serviceConfig = {
        MemoryHigh = "1500M";
        MemoryMax = "2500M";
      };
    }
    // lib.optionalAttrs (hasModule "kavita") {

      kavita.serviceConfig = {
        MemoryHigh = "750M";
        MemoryMax = "1G";
        CPUQuota = "150%";
        CPUWeight = 60;
        IOWeight = 60;
        Nice = 5;
      };

      kavita-stale-reference-cleanup.serviceConfig = {
        CPUQuota = "75%";
        CPUWeight = 40;
        IOWeight = 40;
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };
    }
    // lib.optionalAttrs (hasModule "audiobookshelf") {

      audiobookshelf-stale-reference-cleanup.serviceConfig = {
        CPUQuota = "75%";
        CPUWeight = 40;
        IOWeight = 40;
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };
    }
    // lib.optionalAttrs (hasModule "jellyfin") {

      jellyfin-library-sync.serviceConfig = {
        CPUQuota = "100%";
        CPUWeight = 40;
        IOWeight = 40;
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };

      jellyfin.serviceConfig = {
        MemoryHigh = "1G";
        MemoryMax = "2G";
      };
    }
    // lib.optionalAttrs (hasModule "youtube-downloader") {
      youtube-downloader.serviceConfig.CPUQuota = "200%";
    }
    // lib.optionalAttrs (moduleEnabled "sonarr") {
      sonarr.serviceConfig = { MemoryHigh = "500M"; MemoryMax = "750M"; };
    }
    // lib.optionalAttrs (moduleEnabled "radarr") {
      radarr.serviceConfig = { MemoryHigh = "500M"; MemoryMax = "750M"; };
    }
    // lib.optionalAttrs (moduleEnabled "prowlarr") {
      prowlarr.serviceConfig = { MemoryHigh = "500M"; MemoryMax = "750M"; };
    };
  }

  (lib.mkIf power.enable {
    networking.interfaces.${power.wakeOnLan.interface}.wakeOnLan = lib.mkIf power.wakeOnLan.enable {
      enable = true;
      policy = power.wakeOnLan.policy;
    };

    environment.systemPackages = systemPackages;

    powerManagement.cpuFreqGovernor = power.cpuGovernor;
    powerManagement.powertop.enable = power.powertopAutoTune;
    powerManagement.scsiLinkPolicy = power.scsiLinkPolicy;

    services.fstrim.enable = true;
    services.fstrim.interval = power.fstrimCalendar;
    services.udev.extraRules = lib.mkIf usbCfg.enable usbAutoSuspendRules;
  })

  (lib.mkIf (power.enable && nightlySuspend.enable) {
    systemd.sleep.extraConfig = ''
      AllowSuspend=yes
      AllowHibernation=no
      AllowHybridSleep=no
      AllowSuspendThenHibernate=no
      SuspendState=mem
    '';

    systemd.services.power-management-nightly-suspend = {
      description = "Nightly suspend with RTC wake scheduling";
      path = nightlySuspendPath;
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        for unit in ${blockerUnits}; do
          load_state="$(systemctl show --property LoadState --value "$unit" 2>/dev/null || true)"
          if [[ -z "$load_state" || "$load_state" == "not-found" ]]; then
            continue
          fi

          if systemctl is-active --quiet "$unit"; then
            echo "Skipping nightly suspend because blocker unit is active: $unit"
            exit 0
          fi
        done

        if ${lib.boolToString power.skipIfSshSessions}; then
          if who | grep -qE '\([[:alnum:]:._-]+\)$'; then
            echo "Skipping nightly suspend because an SSH session is active."
            exit 0
          fi
        fi

        if ${lib.boolToString power.skipIfOtherUserSessions}; then
          if who | awk '$1 != "root" { found = 1 } END { exit(found ? 0 : 1) }'; then
            echo "Skipping nightly suspend because a non-root interactive session is active."
            exit 0
          fi
        fi

        now_epoch="$(date +%s)"
        today="$(date +%F)"
        wake_epoch="$(date --date="$today ${wakeTime}" +%s)"

        if [[ "$wake_epoch" -le "$now_epoch" ]]; then
          wake_epoch="$(date --date="tomorrow ${wakeTime}" +%s)"
        fi

        rtcwake -m no -t "$wake_epoch"
        systemctl suspend
      '';
    };

    systemd.timers.power-management-nightly-suspend = {
      description = "Suspend the server each night outside the declared maintenance window";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = nightlySuspend.calendar;
        Persistent = false;
      };
    };
  })
]
