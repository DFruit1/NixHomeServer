{ ... }:

{
  imports = [
    ./package.nix
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.searxng = true;
}
