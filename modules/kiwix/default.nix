{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./backups.nix
    ./networking.nix
    ./service.nix
    ./oauth2-proxy.nix
  ];
}
