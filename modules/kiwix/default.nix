{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./impermanence.nix
    ./backups.nix
    ./networking.nix
    ./service.nix
    ./oauth2-proxy.nix
  ];
}
