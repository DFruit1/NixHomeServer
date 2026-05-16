{ ... }:

{
  imports = [
    ./hardware.nix
    ../../configuration.nix
  ];

  nixhomeserver.profiles = [ "compatibility" ];
}
