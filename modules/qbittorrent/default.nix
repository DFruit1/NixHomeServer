{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.qbittorrent = true;
}
