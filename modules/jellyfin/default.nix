{ ... }:

{
  imports = [
    ./storage.nix
    ./library-bootstrap.nix
    ./library-sync.nix
    ./library-monitor.nix
    ./library-watch.nix
    ./service.nix
    ./network-config.nix
  ];
}
