{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./impermanence.nix
    ./backups.nix
    ./networking.nix
    ./storage.nix
    ./service.nix
    ./oidc-bootstrap.nix
    ./root-bootstrap.nix
    ./library-watch.nix
  ];
}
