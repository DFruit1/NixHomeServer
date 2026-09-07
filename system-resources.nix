{ config, lib, pkgs, vars, ... }:

let
  power = {
    enable = true;
    cpuGovernor = "powersave";
    nightlySuspend = {
      # Suspends to RAM (S3): while suspended, Cloudflare Tunnel, DNS, and all
      # hosted services are offline until the RTC wake. From 22:00 the host is
      # re-checked every 15 minutes and suspended only while idle (low CPU,
      # disk, network, and memory usage); from midnight the suspend is forced
      # regardless of load, and the host wakes at wakeTime. Overnight
      # Persistent=true maintenance timers catch up after the wake.
      enable = true;
      idleCheckCalendar = "*-*-* 22,23:00/15:00"; # Usage-gated checks at 22:00, 22:15, ... 23:45.
      forcedCalendar = "*-*-* 00..09:00:00"; # Guaranteed midnight cutoff plus hourly retries if a suspend was inhibited.
      wakeTime = "10:30";
      idleWindowStartHour = 22; # First hour of usage-gated checks.
      forcedWindowEndHour = 10; # Hours before this (00:00-09:59) force the suspend.
      sampleSeconds = 10; # Usage sampling window for each evening check.
      cpuBusyPercent = 25; # CPU busy percentage at or above which the host counts as active.
      diskBusyKiBps = 512; # Disk throughput at or above which the host counts as active.
      netBusyKiBps = 512; # Network throughput at or above which the host counts as active.
      memAvailablePercent = 10; # Available-memory floor below which the host counts as active.
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

  blockerUnits = lib.escapeShellArgs (
    power.blockerUnits
    ++ lib.optionals (hasModule "mkvmaker") [ "mkvmaker-import-worker.service" ]
  );
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
      options zfs zfs_arc_min=536870912
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
      lib.optionalAttrs vars.enableZfsDataPool {
        zfs-arc-tune = {
          description = "Set ZFS ARC maximum to a percentage of system RAM";
          wantedBy = [ "zfs-import-cache.service" ];
          before = [ "zfs-import-cache.service" ];
          after = [ "systemd-modules-load.service" ];
          unitConfig.DefaultDependencies = false;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
          };
          script = ''
            total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
            arc_max=$(( total_kb * 1024 * ${toString (vars.zfsArcMaxPercent or 50)} / 100 ))
            echo "$arc_max" > /sys/module/zfs/parameters/zfs_arc_max
          '';
        };
      }
      // lib.optionalAttrs (hasModule "immich") {
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
    systemd.sleep.settings.Sleep = {
      AllowSuspend = "yes";
      AllowHibernation = "no";
      AllowHybridSleep = "no";
      AllowSuspendThenHibernate = "no";
      SuspendState = "mem";
    };

    systemd.services.power-management-nightly-suspend = {
      description = "Nightly suspend: usage-gated evening checks with a guaranteed midnight cutoff";
      path = nightlySuspendPath;
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        hour="$(date +%-H)"
        now_epoch="$(date +%s)"

        if [[ "$hour" -ge ${toString nightlySuspend.forcedWindowEndHour} && "$hour" -lt ${toString nightlySuspend.idleWindowStartHour} ]]; then
          echo "Daytime hours; suspend is not considered before ${toString nightlySuspend.idleWindowStartHour}:00."
          exit 0
        fi

        today="$(date +%F)"
        wake_epoch="$(date --date="$today ${wakeTime}" +%s)"
        if [[ "$wake_epoch" -le "$now_epoch" ]]; then
          wake_epoch="$(date --date="tomorrow ${wakeTime}" +%s)"
        fi

        suspend_now() {
          echo "Scheduling RTC wake at ${wakeTime} and suspending."
          rtcwake -m no -t "$wake_epoch"
          systemctl suspend
        }

        if [[ "$hour" -lt ${toString nightlySuspend.forcedWindowEndHour} ]]; then
          # Guaranteed overnight cutoff: suspend regardless of load, sessions,
          # or blocker units. The hourly timer retries if this was inhibited.
          suspend_now
          exit 0
        fi

        # Evening usage-gated window: suspend only while the host is idle.
        for unit in ${blockerUnits}; do
          load_state="$(systemctl show --property LoadState --value "$unit" 2>/dev/null || true)"
          if [[ -z "$load_state" || "$load_state" == "not-found" ]]; then
            continue
          fi

          if systemctl is-active --quiet "$unit"; then
            echo "Deferring suspend because blocker unit is active: $unit"
            exit 0
          fi
        done

        if ${lib.boolToString power.skipIfSshSessions}; then
          if who | grep -qE '\([[:alnum:]:._-]+\)$'; then
            echo "Deferring suspend because an SSH session is active."
            exit 0
          fi
        fi

        if ${lib.boolToString power.skipIfOtherUserSessions}; then
          if who | awk '$1 != "root" { found = 1 } END { exit(found ? 0 : 1) }'; then
            echo "Deferring suspend because a non-root interactive session is active."
            exit 0
          fi
        fi

        read_cpu() { awk 'NR==1 { print $2+$3+$4+$7+$8+$9, $5+$6 }' /proc/stat; }
        read_disk_sectors() { awk '$1 ~ /^(sd|vd|hd)[a-z]+$/ || $1 ~ /^nvme[0-9]+n[0-9]+$/ { sectors += $6 + $10 } END { print sectors + 0 }' /proc/diskstats; }
        read_swap_pages() { awk '$1 == "pswpin" || $1 == "pswpout" { pages += $2 } END { print pages + 0 }' /proc/vmstat; }
        read_net_bytes() {
          awk '
            NR > 2 {
              pos = index($0, ":")
              if (pos > 1) {
                name = substr($0, 1, pos - 1)
                gsub(/ /, "", name)
                if (name != "lo") {
                  rest = substr($0, pos + 1)
                  sub(/^ +/, "", rest)
                  split(rest, f, / +/)
                  total += f[1] + f[9]
                }
              }
            }
            END { print total + 0 }
          ' /proc/net/dev
        }

        read -r cpu_busy_a cpu_idle_a <<< "$(read_cpu)"
        disk_a="$(read_disk_sectors)"
        swap_a="$(read_swap_pages)"
        net_a="$(read_net_bytes)"
        sleep "${toString nightlySuspend.sampleSeconds}"
        read -r cpu_busy_b cpu_idle_b <<< "$(read_cpu)"
        disk_b="$(read_disk_sectors)"
        swap_b="$(read_swap_pages)"
        net_b="$(read_net_bytes)"

        cpu_total=$(( (cpu_busy_b + cpu_idle_b) - (cpu_busy_a + cpu_idle_a) ))
        cpu_pct=0
        if (( cpu_total > 0 )); then
          cpu_pct=$(( 100 * (cpu_busy_b - cpu_busy_a) / cpu_total ))
        fi
        disk_kbps=$(( (disk_b - disk_a) * 512 / 1024 / ${toString nightlySuspend.sampleSeconds} ))
        net_kbps=$(( (net_b - net_a) / 1024 / ${toString nightlySuspend.sampleSeconds} ))
        swap_delta=$(( swap_b - swap_a ))
        mem_avail_pct="$(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END { if (t > 0) printf "%d", 100*a/t; else print 0 }' /proc/meminfo)"

        echo "usage sample: cpu=''${cpu_pct}%, disk=''${disk_kbps} KiB/s, net=''${net_kbps} KiB/s, mem_available=''${mem_avail_pct}%, swap_delta=''${swap_delta} pages"

        if (( cpu_pct >= ${toString nightlySuspend.cpuBusyPercent} )); then
          echo "Deferring suspend: CPU usage ''${cpu_pct}% >= ${toString nightlySuspend.cpuBusyPercent}% threshold."
          exit 0
        fi

        if (( disk_kbps >= ${toString nightlySuspend.diskBusyKiBps} )); then
          echo "Deferring suspend: disk throughput ''${disk_kbps} KiB/s >= ${toString nightlySuspend.diskBusyKiBps} KiB/s threshold."
          exit 0
        fi

        if (( net_kbps >= ${toString nightlySuspend.netBusyKiBps} )); then
          echo "Deferring suspend: network throughput ''${net_kbps} KiB/s >= ${toString nightlySuspend.netBusyKiBps} KiB/s threshold."
          exit 0
        fi

        if (( mem_avail_pct < ${toString nightlySuspend.memAvailablePercent} )); then
          echo "Deferring suspend: available memory ''${mem_avail_pct}% < ${toString nightlySuspend.memAvailablePercent}% threshold."
          exit 0
        fi

        if (( swap_delta > 0 )); then
          echo "Deferring suspend: swap activity detected (''${swap_delta} pages)."
          exit 0
        fi

        suspend_now
      '';
    };

    systemd.timers.power-management-nightly-suspend = {
      description = "Nightly suspend: usage-gated checks from ${toString nightlySuspend.idleWindowStartHour}:00, guaranteed cutoff at midnight";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = [
          nightlySuspend.idleCheckCalendar
          nightlySuspend.forcedCalendar
        ];
        Persistent = false;
      };
    };
  })
]
