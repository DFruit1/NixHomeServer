{ ... }:

{
  imports = [
    ./library-sync.nix
    ./service.nix
    ./oidc-bootstrap.nix
    ./root-bootstrap.nix
  ];
}
