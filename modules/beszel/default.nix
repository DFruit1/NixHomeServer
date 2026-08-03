{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.beszel = true;
}
