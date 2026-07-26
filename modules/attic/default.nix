{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./bootstrap.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.attic = true;
}
