{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./library-watch.nix
    ./bootstrap.nix
    ./backups.nix
  ];
}
