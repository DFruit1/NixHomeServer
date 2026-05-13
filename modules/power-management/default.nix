{ config, lib, pkgs, vars, ... }:

let
  cfg = vars.powerManagement;
  usbCfg = cfg.usbAutoSuspend;
  kernelPackages = config.boot.kernelPackages;

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

  blockerUnits = lib.escapeShellArgs cfg.blockerUnits;
  wakeTime = lib.escapeShellArg cfg.wakeTime;
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
      kernelPackages.turbostat
    ];
in
lib.mkIf cfg.enable {
  networking.interfaces.${cfg.wakeOnLan.interface}.wakeOnLan = lib.mkIf cfg.wakeOnLan.enable {
    enable = true;
    policy = cfg.wakeOnLan.policy;
  };

  environment.systemPackages = systemPackages;

  powerManagement.cpuFreqGovernor = cfg.cpuGovernor;
  powerManagement.powertop.enable = cfg.powertopAutoTune;
  powerManagement.scsiLinkPolicy = cfg.scsiLinkPolicy;

  services.fstrim.enable = true;
  services.fstrim.interval = cfg.fstrimCalendar;
  services.udev.extraRules = lib.mkIf usbCfg.enable usbAutoSuspendRules;

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

      if ${lib.boolToString cfg.skipIfSshSessions}; then
        if who | grep -qE '\([[:alnum:]:._-]+\)$'; then
          echo "Skipping nightly suspend because an SSH session is active."
          exit 0
        fi
      fi

      if ${lib.boolToString cfg.skipIfOtherUserSessions}; then
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
      OnCalendar = cfg.suspendCalendar;
      Persistent = false;
    };
  };
}
