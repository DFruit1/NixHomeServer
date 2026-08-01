{ ... }:

{
  imports = [
    ./options.nix
    ./identity.nix
    ./networking.nix
    ./storage.nix
    ./services.nix
    ./backups.nix
  ];
}
