{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./backups.nix
    ./networking.nix
    ./storage.nix
    ./service.nix
    ./admin-reconcile.nix
    ./public-proxy.nix
  ];
}
