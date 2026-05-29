{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./oidc-reconcile.nix
    ./bootstrap.nix
    ./backups.nix
  ];
}
