{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];
}
