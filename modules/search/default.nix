{ ... }:

{
  imports = [
    ./backups.nix
    ./bootstrap.nix
    ./filepaths.nix
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./semantic.nix
  ];

  nixhomeserver.modules.search = true;
}
