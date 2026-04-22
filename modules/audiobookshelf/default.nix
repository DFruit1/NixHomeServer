{ ... }:

{
  imports = [
    ./service.nix
    ./storage-migration.nix
    ./oidc-bootstrap.nix
    ./root-bootstrap.nix
  ];
}
