{ ... }:

{
  imports = [
    ./hardware.nix
    ../../configuration.nix
  ];

  nixhomeserver.profiles = [
    "core"
    "files"
  ];
  nixhomeserver.validation.allowPlaceholders = true;
}
