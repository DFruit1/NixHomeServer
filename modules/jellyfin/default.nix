{ ... }:

{
  imports = [
    ./service.nix
    ./network-config.nix
    ./user-sync.nix
    ./library-sync.nix
  ];
}
