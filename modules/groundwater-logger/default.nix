{ ... }:

{
  imports = [
    ./identity.nix
    ./filepaths.nix
    ./networking.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.groundwater-logger = true;
}
