{ ... }:

{
  imports = [
    ./library-sync.nix
    ./library-monitor.nix
    ./service.nix
    ./network-config.nix
  ];
}
