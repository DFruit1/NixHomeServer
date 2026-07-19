{ lib, vars, ... }:

let
  storageValidation = import ../lib/storage-validation.nix { inherit lib; };
  rootSubvolume = if vars.enableRootRollback then "/root" else "/";
  rootContent =
    if vars.storageProfile == "single-disk-ext4" then
      {
        type = "filesystem";
        format = "ext4";
        mountpoint = "/";
        postCreateHook = ''
          (
            root_mount="$(mktemp -d)"
            trap 'umount "$root_mount" 2>/dev/null || true; rmdir "$root_mount" 2>/dev/null || true' EXIT
            mount "$device" "$root_mount"
            install -d -m 0755 "$root_mount/persist" "$root_mount/nix"
          )
        '';
      }
    else
      {
        type = "btrfs";
        subvolumes = {
          ${rootSubvolume} = {
            mountpoint = "/";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
          "/nix" = {
            mountpoint = "/nix";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
          "/persist" = {
            mountpoint = "/persist";
            mountOptions = [ "compress=zstd" "noatime" ];
          };
        } // lib.optionalAttrs vars.enableRootRollback {
          # Disko creates the writable root first. The hook below turns this
          # second, empty subvolume into the immutable rollback source.
          "/root-blank" = { };
        };
        postCreateHook = lib.optionalString vars.enableRootRollback ''
          (
            rollback_mount="$(mktemp -d)"
            trap 'umount "$rollback_mount" 2>/dev/null || true; rmdir "$rollback_mount" 2>/dev/null || true' EXIT
            mount -t btrfs -o subvolid=5 "$device" "$rollback_mount"

            test -d "$rollback_mount/root"
            test -d "$rollback_mount/root-blank"
            btrfs property set -ts "$rollback_mount/root-blank" ro true
          )
        '';
      };
  systemDiskValid =
    if !storageValidation.validDiskId vars.mainDisk then
      throw "storage.systemDisk must be a safe, non-placeholder /dev/disk/by-id basename before disk bootstrap."
    else
      true;
in

assert systemDiskValid;
{
  assertions = [
    {
      assertion = builtins.elem vars.storageProfile [ "zfs-mirror" "single-disk-ext4" ];
      message = "Unsupported storage.profile '${vars.storageProfile}' for disko-system.nix.";
    }
    {
      assertion = storageValidation.validDiskId vars.mainDisk;
      message = "storage.systemDisk must be a safe, non-placeholder /dev/disk/by-id basename before disk bootstrap.";
    }
    {
      assertion = !vars.enableRootRollback || vars.storageProfile == "zfs-mirror";
      message = "storage.enableRootRollback requires storage.profile = zfs-mirror before disk bootstrap.";
    }
  ];

  disko.devices = {
    disk = {
      ##############################################################
      #  System disk                                                #
      ##############################################################
      system = {
        device = "/dev/disk/by-id/${vars.mainDisk}";
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            boot = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };

            root = {
              size = "100%";
              content = rootContent;
            };
          };
        };
      };
    };
  };
}
