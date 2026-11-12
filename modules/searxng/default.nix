{ ... }:

{
  imports = [
    ./package.nix
    ./identity.nix
    ./networking.nix
    ./bootstrap.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.searxng = true;
}
