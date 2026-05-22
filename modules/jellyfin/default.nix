{ ... }:

{
  imports = [
    ./filepaths.nix
    ./identity.nix
    ./backups.nix
    ./networking.nix
    ./storage.nix
    ./library-bootstrap.nix
    ./library-sync.nix
    ./library-monitor.nix
    ./library-watch.nix
    ./service.nix
    ./network-config.nix
  ];
}
