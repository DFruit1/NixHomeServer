{ ... }:

{
  imports = [
    ./storage.nix
    ./service.nix
    ./oidc-bootstrap.nix
    ./root-bootstrap.nix
    ./library-watch.nix
  ];
}
