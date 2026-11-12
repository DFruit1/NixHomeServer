{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./bootstrap.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.filesync = true;
}
