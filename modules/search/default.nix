{ ... }:

{
  imports = [
    ./backups.nix
    ./bootstrap.nix
    ./filepaths.nix
    ./identity.nix
    ./networking.nix
    ./services.nix
  ];

  nixhomeserver.modules.search = true;
}
