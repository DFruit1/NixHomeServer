{ ... }:

{
  imports = [
    ../common/system-ssd-btrfs.nix
  ];

  # A real install should replace or extend this with nixos-generate-config
  # output for hardware-specific kernel modules and platform settings.
}
