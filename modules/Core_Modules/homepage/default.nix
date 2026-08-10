{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./services.nix
    ./canary.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.homepage = true;
}
