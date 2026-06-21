{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./permissions.nix
    ./bootstrap.nix
    ./backups.nix
  ];
}
