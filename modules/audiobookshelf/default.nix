{ ... }:

{
  imports = [
    ./service.nix
    ./oidc-bootstrap.nix
    ./root-bootstrap.nix
  ];
}
