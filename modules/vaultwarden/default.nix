{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];
}
