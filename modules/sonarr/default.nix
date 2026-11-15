{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
    ./media-manager.nix
  ];

  nixhomeserver.modules.sonarr = true;
}
