{ lib, pkgs, vars, ... }:

let
  externalUsbMountRoot = vars.externalUsbMountRoot or "/mnt/external-usb";
  externalUsbViewMount = vars.externalUsbViewMount or "/mnt/usb-access-view";
  usbAccessGroup = vars.fileAccess.usbAccessGroup or "usb-access";
  usbAccessGid = vars.fileAccessPosixGids.${usbAccessGroup};
  usbMountName = vars.fileAccess.usbMountName or "_USB";
  usbViewLink = "${vars.sharedRoot}/${usbMountName}";
  mountScript = pkgs.writeShellScript "usb-media-mount" ''
    set -euo pipefail

    kernel_name="$1"
    device="/dev/$kernel_name"
    usb_gid=${toString usbAccessGid}
    mount_root=${lib.escapeShellArg externalUsbMountRoot}

    ${pkgs.systemd}/bin/udevadm settle --timeout=30

    [[ -b "$device" ]] || exit 0

    fstype="$(${pkgs.util-linux}/bin/lsblk -rn -o FSTYPE "$device" 2>/dev/null || true)"
    [[ -n "$fstype" ]] || exit 0

    if ${pkgs.util-linux}/bin/findmnt -n "$device" >/dev/null 2>&1; then
      exit 0
    fi

    label="$(${pkgs.util-linux}/bin/lsblk -rn -o LABEL "$device" 2>/dev/null || true)"
    partlabel="$(${pkgs.util-linux}/bin/lsblk -rn -o PARTLABEL "$device" 2>/dev/null || true)"
    uuid="$(${pkgs.util-linux}/bin/lsblk -rn -o UUID "$device" 2>/dev/null || true)"

    name="''${label:-''${partlabel:-''${uuid:-$kernel_name}}}"
    name="$(${pkgs.coreutils}/bin/printf '%s' "$name" | ${pkgs.gnused}/bin/sed -e 's/[^A-Za-z0-9._-]//g')"
    [[ -n "$name" ]] || name="$kernel_name"

    mountpoint="$mount_root/$name"
    ${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root "$mountpoint"

    case "$fstype" in
      vfat|exfat)
        ${pkgs.util-linux}/bin/mount -t "$fstype" \
          -o "uid=0,gid=$usb_gid,umask=0007,dmask=0007,fmask=0007" \
          "$device" "$mountpoint"
        ;;
      ntfs)
        if ! ${pkgs.util-linux}/bin/mount -t ntfs3 \
          -o "uid=0,gid=$usb_gid,umask=0007,dmask=0007,fmask=0007" \
          "$device" "$mountpoint" 2>/dev/null; then
          ${pkgs.util-linux}/bin/mount -t ntfs \
            -o "uid=0,gid=$usb_gid,umask=0007,dmask=0007,fmask=0007" \
            "$device" "$mountpoint"
        fi
        ;;
      *)
        ${pkgs.util-linux}/bin/mount "$device" "$mountpoint"
        ;;
    esac
  '';
  unmountScript = pkgs.writeShellScript "usb-media-unmount" ''
    set -euo pipefail

    kernel_name="$1"
    device="/dev/$kernel_name"
    mount_root=${lib.escapeShellArg externalUsbMountRoot}

    if ! ${pkgs.util-linux}/bin/findmnt -n "$device" >/dev/null 2>&1; then
      exit 0
    fi

    while IFS= read -r mountpoint; do
      case "$mountpoint" in
        "$mount_root"/*)
          ${pkgs.util-linux}/bin/umount "$mountpoint" 2>/dev/null || true
          ${pkgs.coreutils}/bin/rmdir "$mountpoint" 2>/dev/null || true
          ;;
      esac
    done < <(${pkgs.util-linux}/bin/findmnt -rn -o TARGET --source "$device" 2>/dev/null || true)
  '';
  waitUsbGroup = pkgs.writeShellScript "wait-usb-access-group" ''
    for _ in $(seq 1 90); do
      if ${pkgs.getent}/bin/getent group ${lib.escapeShellArg usbAccessGroup} >/dev/null; then
        exit 0
      fi
      sleep 1
    done
    echo "Kanidm group ${lib.escapeShellArg usbAccessGroup} did not become resolvable" >&2
    exit 1
  '';
in
{
  config = {
    assertions = [
      {
        assertion = lib.hasPrefix "/mnt/" externalUsbViewMount;
        message = "externalUsbViewMount must be a normalized absolute path below /mnt.";
      }
    ];

    services.udev.extraRules = ''
      ACTION=="add|change", SUBSYSTEM=="block", KERNEL=="sd[a-z]*|sd[a-z]*[0-9]*|mmcblk[0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="disk|partition", IMPORT{builtin}="blkid", ENV{ID_FS_TYPE}!="", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-media-automount@%k.service"
      ACTION=="remove", SUBSYSTEM=="block", KERNEL=="sd[a-z]*|sd[a-z]*[0-9]*|mmcblk[0-9]*|mmcblk[0-9]*p[0-9]*|nvme[0-9]*n[0-9]*|nvme[0-9]*n[0-9]*p[0-9]*", ENV{ID_BUS}=="usb", ENV{DEVTYPE}=="disk|partition", TAG+="systemd", ENV{SYSTEMD_WANTS}+="usb-media-autounmount@%k.service"
    '';

    systemd.tmpfiles.rules = [
      "d ${externalUsbMountRoot} 0755 root root -"
      "d ${externalUsbViewMount} 0755 root root -"
    ];

    systemd.services."usb-media-automount@" = {
      description = "Auto-mount inserted external USB storage device %I";
      unitConfig.ConditionPathIsDirectory = externalUsbMountRoot;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ mountScript "%I" ];
      };
    };

    systemd.services."usb-media-autounmount@" = {
      description = "Unmount removed external USB storage device %I";
      unitConfig.ConditionPathIsDirectory = externalUsbMountRoot;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [ unmountScript "%I" ];
      };
    };

    systemd.services.files-usb-shared-view = {
      description = "Expose auto-mounted external USB media to usb-access members";
      wantedBy = [ "multi-user.target" ];
      wants = [ "kanidm-unixd.service" "kanidm-files-posix-groups.service" ];
      after = [ "kanidm-unixd.service" "kanidm-files-posix-groups.service" ];
      unitConfig.ConditionPathIsDirectory = externalUsbMountRoot;
      serviceConfig = {
        Type = "simple";
        ExecStartPre = [
          waitUsbGroup
          "${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${externalUsbViewMount}"
        ];
        ExecStart = "${pkgs.bindfs}/bin/bindfs -f -o allow_other --mirror-only=@${usbAccessGroup} --force-group=${toString usbAccessGid} --perms=g+rwX,o-rwx ${externalUsbMountRoot} ${externalUsbViewMount}";
        ExecStop = "-${pkgs.fuse3}/bin/fusermount3 -u ${externalUsbViewMount}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.services.files-usb-shared-link = {
      description = "Link the shared external USB view into the shared files root";
      wantedBy = [ "multi-user.target" ];
      wants = [ "files-usb-shared-view.service" ];
      after = [ "files-usb-shared-view.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        link=${lib.escapeShellArg usbViewLink}

        if [[ -L "$link" ]]; then
          if [[ "$(${pkgs.coreutils}/bin/readlink "$link")" != ${lib.escapeShellArg externalUsbViewMount} ]]; then
            ${pkgs.coreutils}/bin/ln -sfn ${lib.escapeShellArg externalUsbViewMount} "$link"
          fi
        elif [[ -d "$link" ]]; then
          if [[ -z "$(${pkgs.coreutils}/bin/ls -A "$link" 2>/dev/null)" ]]; then
            ${pkgs.coreutils}/bin/rmdir "$link"
            ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg externalUsbViewMount} "$link"
          else
            echo "Refusing to replace non-empty ${lib.escapeShellArg usbViewLink}" >&2
            exit 1
          fi
        else
          ${pkgs.coreutils}/bin/ln -s ${lib.escapeShellArg externalUsbViewMount} "$link"
        fi
      '';
    };

    repo.storage.dataPool.guardedServices = [ "files-usb-shared-link" ];
  };
}
