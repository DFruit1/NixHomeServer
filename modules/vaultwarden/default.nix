{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];
}
