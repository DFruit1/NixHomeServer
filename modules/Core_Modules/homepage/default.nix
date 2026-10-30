{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./services.nix
    ./dashboard.nix
    ./logs.nix
    ./canary.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.homepage = true;
}
