{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./impermanence.nix
    ./backups.nix
    ./networking.nix
    ./package.nix
    ./storage.nix
    ./service.nix
    ./bootstrap.nix
  ];
}
