{ ... }:

{
  imports = [
    ./storage.nix
    ./service.nix
    ./admin-reconcile.nix
    ./public-proxy.nix
  ];
}
